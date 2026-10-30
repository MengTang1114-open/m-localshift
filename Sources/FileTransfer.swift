import Foundation

/// Copy or move files for the "move to folder" action. All-or-nothing: a failure
/// rolls back what was already done.
enum FileTransfer {
    private static let serial = NSLock()
    private static let stateLock = NSLock()
    private static var cancelled = false

    static func cancel() {
        stateLock.lock(); cancelled = true; stateLock.unlock()
    }

    private static func check() throws {
        stateLock.lock(); let value = cancelled; stateLock.unlock()
        if value { throw ConverterError.cancelled }
    }

    static func perform(_ files: [URL], to folder: URL, move: Bool, progress: @escaping (Double, String) -> Void) throws -> [URL] {
        guard serial.try() else { throw ConverterError.message("已有文件操作正在运行。") }
        defer { serial.unlock() }
        stateLock.lock(); cancelled = false; stateLock.unlock()
        let fm = FileManager.default
        guard !files.isEmpty else { throw ConverterError.message("没有选择文件。") }
        let destination = folder.resolvingSymlinksInPath().standardizedFileURL
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &directory), directory.boolValue else { throw ConverterError.message("目标文件夹不存在。") }
        var names = Set<String>()
        for file in files {
            guard fm.fileExists(atPath: file.path) else { throw ConverterError.message("源文件不存在：\(file.lastPathComponent)") }
            let source = file.resolvingSymlinksInPath().standardizedFileURL
            guard destination.path != source.path, !destination.path.hasPrefix(source.path + "/") else { throw ConverterError.message("不能将文件夹复制或移动到它自身内部。") }
            if move {
                let target = destination.appendingPathComponent(file.lastPathComponent)
                guard !fm.fileExists(atPath: target.path), names.insert(file.lastPathComponent.lowercased()).inserted else {
                    throw ConverterError.message("目标中存在同名文件，尚未移动任何文件：\(file.lastPathComponent)")
                }
            }
        }
        var done: [(source: URL, output: URL)] = []
        do {
            for (index, file) in files.enumerated() {
                progress(Double(index) / Double(files.count), (move ? "移动 " : "复制 ") + file.lastPathComponent)
                try check()
                let output = move ? destination.appendingPathComponent(file.lastPathComponent) : ConverterEngine.uniqueURL(in: destination, name: file.lastPathComponent)
                if move { try fm.moveItem(at: file, to: output) } else { try fm.copyItem(at: file, to: output) }
                done.append((file, output))
            }
            try check()
            progress(1, "已完成")
            return done.map(\.output)
        } catch {
            var rollbackErrors: [String] = []
            for item in done.reversed() {
                do {
                    if move { try fm.moveItem(at: item.output, to: item.source) } else { try fm.removeItem(at: item.output) }
                } catch { rollbackErrors.append(item.output.path) }
            }
            if !rollbackErrors.isEmpty { throw ConverterError.message("文件操作未完成，部分项目未能还原，请检查：\n" + rollbackErrors.joined(separator: "\n")) }
            throw error
        }
    }
}
