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

    /// Finds ffmpeg in the places it is normally installed.
    ///
    /// The search does not follow PATH. A program named ffmpeg earlier in PATH
    /// would be run with this application's privileges, and it is handed the
    /// key to the audio, so what runs is not something to leave to whatever a
    /// shell was configured with.
    static func locateFFmpeg() -> URL? {
        for path in searchPaths where isSafeToRun(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// True when a file is one this application will run.
    ///
    /// A file anybody can write to is a file anybody can replace, so being
    /// executable is not enough on its own.
    static func isSafeToRun(_ path: String) -> Bool {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: path),
              let attributes = try? manager.attributesOfItem(atPath: path),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        else { return false }

        // Writable by the group or by everybody means anybody can swap it.
        let groupWrite: UInt16 = 0o020
        let otherWrite: UInt16 = 0o002
        guard permissions & (groupWrite | otherWrite) == 0 else { return false }

        // A link can point anywhere. Judge what it points at.
        if let destination = try? manager.destinationOfSymbolicLink(atPath: path) {
            let resolved = destination.hasPrefix("/")
                ? destination
                : URL(fileURLWithPath: path).deletingLastPathComponent()
                    .appendingPathComponent(destination).standardizedFileURL.path
            return resolved == path ? true : isSafeToRun(resolved)
        }
        return true
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

        Log.write("Decrypting \(source.lastPathComponent) to \(destination.lastPathComponent)")
        try process.run()
        let errorText = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            Log.write("ffmpeg failed with status \(process.terminationStatus): \(errorText)")
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
    /// The check exists to catch a file that stops early, which plays as a
    /// truncated book. It is deliberately loose: the reported runtime is
    /// rounded to whole minutes and often omits credits, so a real file can
    /// run several minutes longer than the library claims. Only a file that is
    /// clearly short is treated as a failure, and a file that runs long is
    /// always accepted.
    ///
    /// This is a second line rather than the first. A container keeps its own
    /// idea of its length, and that survives the file being cut, so a
    /// half-finished download can still claim the full duration. The count of
    /// bytes against what the server said is what actually catches that, and
    /// it happens as the file arrives.
    static let shortestAcceptedShare = 0.95

    func verify(_ file: URL, against expectedDuration: TimeInterval) throws {
        guard let actual = duration(of: file) else {
            try? FileManager.default.removeItem(at: file)
            throw AudibleError.decryptFailed("The decrypted file reports no duration.")
        }

        let shortest = expectedDuration * DecryptService.shortestAcceptedShare
        Log.write("Decrypted file runs \(Int(actual))s; "
                  + "the library reports \(Int(expectedDuration))s; "
                  + "the shortest accepted is \(Int(shortest))s.")

        guard actual >= shortest else {
            try? FileManager.default.removeItem(at: file)
            throw AudibleError.decryptFailed(
                "The decrypted file is \(Int(actual / 60)) minutes long, "
                + "but the library reports \(Int(expectedDuration / 60)). "
                + "The download stopped early.")
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
