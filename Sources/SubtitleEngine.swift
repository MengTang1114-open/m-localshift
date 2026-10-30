import Foundation

/// SRT / VTT / plain-text subtitle conversion. Pure text processing, no runtimes.
enum SubtitleEngine {
    private struct Cue { var start: String; var end: String; var text: String }

    static func convert(_ file: URL, format: String, scratch: URL) throws -> URL {
        guard ["srt", "vtt", "txt"].contains(format) else { throw ConverterError.message("不支持的字幕格式。") }
        let cues = try parse(String(contentsOf: file, encoding: .utf8))
        let output = scratch.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "." + format)
        try render(cues, as: format).write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    private static func parse(_ raw: String) throws -> [Cue] {
        let input = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let timing = try NSRegularExpression(pattern: #"(?m)^(?:(\d{2,}):)?(\d{2}):(\d{2})[,.](\d{3})\s+-->\s+(?:(\d{2,}):)?(\d{2}):(\d{2})[,.](\d{3})[^\n]*\n"#)
        let text = input as NSString
        let matches = timing.matches(in: input, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { throw ConverterError.message("字幕中未找到有效时间轴。") }
        var cues: [Cue] = []
        for (index, match) in matches.enumerated() {
            func part(_ group: Int) -> String {
                match.range(at: group).location == NSNotFound ? "00" : text.substring(with: match.range(at: group))
            }
            let start = "\(part(1)):\(part(2)):\(part(3)).\(part(4))"
            let end = "\(part(5)):\(part(6)):\(part(7)).\(part(8))"
            let from = NSMaxRange(match.range)
            let to = index + 1 < matches.count ? matches[index + 1].range.location : text.length
            var lines = text.substring(with: NSRange(location: from, length: to - from)).components(separatedBy: "\n")
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            // The next cue's identifier sits just before its timing line, after a blank separator.
            if index + 1 < matches.count, let last = lines.last,
               Int(last.trimmingCharacters(in: .whitespaces)) != nil || (lines.count >= 2 && lines[lines.count - 2].isEmpty) {
                lines.removeLast()
            }
            cues.append(Cue(start: start, end: end, text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return cues
    }

    private static func render(_ cues: [Cue], as format: String) -> String {
        switch format {
        case "txt":
            return cues.map(\.text).joined(separator: "\n\n") + "\n"
        case "vtt":
            return "WEBVTT\n\n" + cues.map { "\($0.start) --> \($0.end)\n\($0.text)\n" }.joined(separator: "\n")
        default:
            func srtTime(_ value: String) -> String { value.replacingOccurrences(of: ".", with: ",") }
            return cues.enumerated().map { index, cue in
                "\(index + 1)\n\(srtTime(cue.start)) --> \(srtTime(cue.end))\n\(cue.text)\n"
            }.joined(separator: "\n")
        }
    }
}
