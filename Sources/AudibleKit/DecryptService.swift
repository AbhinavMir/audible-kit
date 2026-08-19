import Foundation

/// Turns a downloaded AAXC file into a plain M4B.
///
/// ffmpeg copies the audio stream rather than re-encoding it, so the output
/// keeps the source quality, the chapter marks, and the cover art.
public struct DecryptService: Sendable {
    private let ffmpegURL: URL

    /// Places ffmpeg is normally installed, in the order they are tried.
    static let searchPaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]

    /// - Parameter ffmpegURL: Where ffmpeg lives. Found automatically when nil.
    public init(ffmpegURL: URL? = nil) throws {
        if let ffmpegURL {
            self.ffmpegURL = ffmpegURL
            return
        }
        guard let found = DecryptService.locateFFmpeg() else {
            throw AudibleError.ffmpegMissing
        }
        self.ffmpegURL = found
    }

    /// True when ffmpeg is installed. Lets a caller warn before work starts.
    public static var isFFmpegInstalled: Bool { locateFFmpeg() != nil }

    static func locateFFmpeg() -> URL? {
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let pathVariable = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in pathVariable.split(separator: ":") {
            let candidate = "\(directory)/ffmpeg"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Decrypts `source` into `destination`.
    ///
    /// - Parameter expectedDuration: Length the library reported. When given,
    ///   the output is checked against it and a short file is treated as a
    ///   failure rather than silently kept.
    public func decrypt(
        _ source: URL,
        license: ContentLicense,
        to destination: URL,
        expectedDuration: TimeInterval? = nil
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-audible_key", license.keyHex,
            "-audible_iv", license.ivHex,
            "-i", source.path,
            "-c", "copy",
            destination.path
        ]

        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()

        try process.run()
        let errorText = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw AudibleError.decryptFailed(
                errorText.isEmpty
                    ? "ffmpeg exited with status \(process.terminationStatus)."
                    : errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let expectedDuration {
            try verify(destination, against: expectedDuration)
        }
    }

    /// Checks the decrypted file against the length the library reported.
    ///
    /// A file that stops early plays as a truncated book, which is worse than
    /// no file at all, so a mismatch deletes the output.
    func verify(_ file: URL, against expectedDuration: TimeInterval) throws {
        guard let actual = duration(of: file) else {
            try? FileManager.default.removeItem(at: file)
            throw AudibleError.decryptFailed("The decrypted file reports no duration.")
        }
        let difference = abs(actual - expectedDuration)
        guard difference <= 60 else {
            try? FileManager.default.removeItem(at: file)
            throw AudibleError.decryptFailed(
                "The decrypted file is \(Int(actual)) seconds long, "
                + "but the library reports \(Int(expectedDuration)).")
        }
    }

    /// Reads a file's duration with ffprobe, when ffprobe sits beside ffmpeg.
    func duration(of file: URL) -> TimeInterval? {
        let probe = ffmpegURL.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: probe.path) else { return nil }

        let process = Process()
        process.executableURL = probe
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            file.path
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Double(text)
    }
}
