import Cocoa

final class OperationContext {
    private let lock = NSLock()
    private var cancelled = false
    private var child: Process?
    private var stopping = false
    private var stopReason: String?
    private var childGroup: pid_t?
    private var forcedStop: DispatchWorkItem?
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw ConverterError.cancelled }
    }
    func cancel() {
        lock.lock(); cancelled = true; let proc = child; lock.unlock()
        if let proc = proc { stop(proc, reason: "已取消处理。") }
    }
    private func stop(_ proc: Process, reason: String) {
        lock.lock()
        guard child === proc, !stopping else { lock.unlock(); return }
        stopping = true; stopReason = reason
        let group = childGroup
        let force = DispatchWorkItem { [weak self, weak proc] in
            guard let self = self, let proc = proc else { return }
            self.lock.lock()
            // A completed task cancels this work item before another can start.
            let active = self.child === proc && self.stopping
            self.lock.unlock()
            guard active else { return }
            if let group = group { kill(-group, SIGKILL) }
            else if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
        forcedStop = force
        lock.unlock()
        if let group = group { kill(-group, SIGTERM) }
        else if proc.isRunning { proc.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: force)
    }
    @discardableResult func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 1800) throws -> String {
        try check()
        let p=Process(); p.executableURL=URL(fileURLWithPath: executable); p.arguments=arguments
        // A signed application bundle must remain immutable when Python imports modules.
        var environment=ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"]="1"
        p.environment=environment
        p.standardInput=FileHandle.nullDevice
        let log=FileManager.default.temporaryDirectory.appendingPathComponent("LocalShift-log-"+UUID().uuidString)
        FileManager.default.createFile(atPath: log.path,contents:nil)
        let h=try FileHandle(forWritingTo:log); p.standardOutput=h; p.standardError=h
        defer { try? h.close(); try? FileManager.default.removeItem(at:log) }
        lock.lock()
        if cancelled { lock.unlock(); throw ConverterError.cancelled }
        do {
            try p.run(); child=p; stopping=false; stopReason=nil
            // Foundation launches macOS Process jobs in their own process group.
            // Verify ownership before ever signalling a group: never touch the
            // app's group or an unrelated process tree.
            let group = getpgid(p.processIdentifier)
            childGroup = group == p.processIdentifier && group != getpgrp() ? group : nil
            lock.unlock()
        } catch { lock.unlock(); throw error }
        let deadline=DispatchWorkItem { [weak self, weak p] in if let p = p { self?.stop(p, reason: "处理超时，已终止任务。") } }
        DispatchQueue.global().asyncAfter(deadline:.now()+timeout,execute:deadline)
        let watcher=DispatchSource.makeTimerSource(queue:DispatchQueue.global())
        watcher.schedule(deadline:.now()+0.25,repeating:0.25)
        watcher.setEventHandler {
            let size=(try? log.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
            if size>8*1024*1024 { self.stop(p, reason: "处理日志超过安全上限，已终止任务。") }
        }
        watcher.resume()
        p.waitUntilExit();deadline.cancel();watcher.cancel()
        lock.lock()
        let group = childGroup, reason = stopReason
        forcedStop?.cancel(); forcedStop=nil
        child=nil; childGroup=nil; stopReason=nil
        lock.unlock()
        // A wrapper may exit while its children ignore TERM or continue writing.
        // Reap the owned job group before deleting logs/scratch or publishing.
        if let group = group { kill(-group, SIGKILL) }
        try check()
        if let reason = reason { throw ConverterError.message(reason) }
        let text=(try? String(contentsOf:log,encoding:.utf8)) ?? ""
        guard p.terminationStatus==0 else { throw ConverterError.message("处理失败："+String(text.suffix(2400))) }
        return text
    }
    static var resourceURL: URL? {
        if let path=ProcessInfo.processInfo.environment["LOCALSHIFT_RESOURCE_DIR"] { return URL(fileURLWithPath:path,isDirectory:true) }
        return Bundle.main.resourceURL
    }
    static var frameworksURL: URL? { resourceURL?.deletingLastPathComponent().appendingPathComponent("Frameworks",isDirectory:true) }
    /// A packaged app uses only its bundled runtimes, so results never depend on
    /// whatever Homebrew happens to have installed. Development and test binaries
    /// outside an .app bundle may fall back to system installs.
    static var allowsSystemRuntime: Bool {
        Bundle.main.bundleURL.pathExtension != "app" || ProcessInfo.processInfo.environment["LOCALSHIFT_ALLOW_SYSTEM_RUNTIME"] == "1"
    }
    static func systemCandidates(_ paths: [String]) -> [String] { allowsSystemRuntime ? paths : [] }
    static func executable(_ name: String) -> String? {
        let override=ProcessInfo.processInfo.environment["LOCALSHIFT_RUNTIME_BIN"].map { URL(fileURLWithPath:$0).appendingPathComponent(name).path }
        let bundled=resourceURL?.appendingPathComponent("bin/"+name).path
        let system=systemCandidates(["/opt/homebrew/bin/"+name,"/usr/local/bin/"+name,"/usr/bin/"+name,"/bin/"+name])
        for path in [override,bundled].compactMap({$0})+system {
            if FileManager.default.isExecutableFile(atPath:path) { return path }
        }
        return nil
    }
}
