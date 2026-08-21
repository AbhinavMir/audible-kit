import Foundation

/// Writes a running log to a file, so a failure that happens inside a window
/// can be read afterwards.
///
/// Nothing secret is written. Tokens, keys, and authorization codes pass
/// through `redacted` first.
public enum Log {
    /// Where the log is written.
    public static let fileURL: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return logs.appendingPathComponent("Earmark.log")
    }()

    private static let queue = DispatchQueue(label: "com.earmarky.log")

    public static func write(_ message: String) {
        let line = "\(stamp()) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? data.write(to: fileURL)
            }
        }
    }

    /// Keeps the first and last few characters so a value can be recognised
    /// across lines without ever being readable.
    public static func redacted(_ value: String) -> String {
        guard value.count > 12 else { return "…" }
        return "\(value.prefix(4))…\(value.suffix(4)) (\(value.count) chars)"
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
