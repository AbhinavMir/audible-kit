import Foundation

/// Plays a title without downloading it first.
///
/// ffmpeg reads the encrypted file straight from Audible over the network,
/// decrypts it, and writes HLS segments to a temporary folder. A local server
/// hands those segments to the player. Nothing large is ever stored: the
/// segments are deleted when the stream stops.
public final class StreamService: @unchecked Sendable {

    /// A stream that is running.
    public struct Stream: Sendable {
        /// The playlist to hand to the player.
        public let playlistURL: URL
        /// Where in the title the stream begins. The player's zero is here.
        public let startOffset: TimeInterval
    }

    /// Seconds of audio per segment. Shorter starts sooner and costs more
    /// requests.
    public static let segmentSeconds = 6
    /// How many segments must exist before the player is handed the playlist.
    static let segmentsBeforeStart = 2

    private let ffmpegURL: URL
    private var process: Process?
    private var server: LocalMediaServer?
    private var workingDirectory: URL?

    public init(ffmpegURL: URL? = nil) throws {
        if let ffmpegURL {
            self.ffmpegURL = ffmpegURL
            return
        }
        guard let found = DecryptService.locateFFmpeg() else { throw AudibleError.ffmpegMissing }
        self.ffmpegURL = found
    }

    deinit {
        stop()
    }

    /// Starts a stream of `license`, beginning at `offset`.
    ///
    /// - Returns: The playlist the player should open.
    public func start(
        _ license: ContentLicense,
        from offset: TimeInterval = 0
    ) async throws -> Stream {
        stop()

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("earmark-stream-\(license.asin)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        workingDirectory = folder

        let process = Process()
        process.executableURL = ffmpegURL
        process.currentDirectoryURL = folder
        process.arguments = StreamService.arguments(for: license, from: offset)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()

        Log.write("Streaming \(license.asin) from \(Int(offset))s.")
        try process.run()
        self.process = process

        let playlist = folder.appendingPathComponent("stream.m3u8")
        try await waitForFirstSegments(playlist: playlist, process: process, errors: errors)

        let server = try LocalMediaServer(directory: folder)
        try await server.start()
        self.server = server

        return Stream(playlistURL: server.url(for: "stream.m3u8"), startOffset: offset)
    }

    /// Stops the stream and deletes everything it wrote.
    public func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        server?.stop()
        server = nil
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        workingDirectory = nil
    }

    /// Builds the ffmpeg arguments.
    ///
    /// `-ss` comes before `-i` so ffmpeg seeks with range requests instead of
    /// reading the whole file up to that point. The audio stream is copied, not
    /// re-encoded, so the stream costs almost no processor time.
    static func arguments(for license: ContentLicense, from offset: TimeInterval) -> [String] {
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-audible_key", license.keyHex,
            "-audible_iv", license.ivHex
        ]
        if offset > 1 {
            arguments += ["-ss", String(format: "%.3f", offset)]
        }
        arguments += [
            "-i", license.downloadURL.absoluteString,
            "-map", "0:a",
            "-c:a", "copy",
            "-f", "hls",
            "-hls_time", String(segmentSeconds),
            "-hls_playlist_type", "event",
            "-hls_flags", "append_list",
            "-hls_segment_type", "fmp4",
            "-hls_segment_filename", "segment%05d.m4s",
            "stream.m3u8"
        ]
        return arguments
    }

    /// Waits until enough of the stream exists for the player to start.
    private func waitForFirstSegments(
        playlist: URL,
        process: Process,
        errors: Pipe
    ) async throws {
        for _ in 0..<120 {
            if !process.isRunning {
                let text = String(
                    data: errors.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
                throw AudibleError.downloadFailed(
                    text.isEmpty ? "The stream stopped before it started." : text)
            }
            let segments = (try? FileManager.default.contentsOfDirectory(
                atPath: playlist.deletingLastPathComponent().path))?
                .filter { $0.hasSuffix(".m4s") } ?? []
            if FileManager.default.fileExists(atPath: playlist.path),
               segments.count >= StreamService.segmentsBeforeStart {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        stop()
        throw AudibleError.downloadFailed("The stream did not start.")
    }
}
