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

    /// Seconds of audio per segment.
    ///
    /// Short segments reach the player sooner, which is what decides how long
    /// a listener waits. The cost is more files and more requests, and neither
    /// matters on a local server.
    public static let segmentSeconds = 2
    /// How many segments must exist before the player is handed the playlist.
    ///
    /// One is enough: the player begins on it while ffmpeg writes the next.
    static let segmentsBeforeStart = 1
    /// How long to wait for that first segment.
    ///
    /// A title the delivery network has not served recently takes far longer
    /// than one it has, and starting partway into a large file adds to that.
    /// This is a deadline rather than a count of attempts, so changing how
    /// often the folder is checked cannot change how long a stream is given.
    static let startDeadline: TimeInterval = 90

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

        // A folder of its own for every attempt. Two attempts at one title
        // shared a folder before, and each new one deleted the segments the
        // other was still writing.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "earmark-stream-\(license.asin)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        workingDirectory = folder

        let process = Process()
        process.executableURL = ffmpegURL
        process.currentDirectoryURL = folder
        process.arguments = StreamService.arguments(for: license, from: offset, in: folder)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()

        Log.write("Streaming \(license.asin) from \(Int(offset))s.")
        try process.run()
        self.process = process

        // The server does not depend on ffmpeg, so it starts while ffmpeg
        // fetches rather than after it.
        async let started: Void = {
            let server = try LocalMediaServer(directory: folder)
            try await server.start()
            self.server = server
        }()

        let playlist = folder.appendingPathComponent("stream.m3u8")
        try await waitForFirstSegments(playlist: playlist, process: process, errors: errors)
        try await started
        guard let server else {
            throw AudibleError.downloadFailed("The local server did not start.")
        }

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
    static func arguments(
        for license: ContentLicense,
        from offset: TimeInterval,
        in folder: URL
    ) -> [String] {
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            // Enough of the file to know what the audio is, and no more. The
            // default reads far more before it writes anything.
            "-probesize", "500000",
            "-analyzeduration", "1000000",
            // The delivery network blocks ffmpeg's own agent with a 403 that
            // says only "request blocked".
            "-user_agent", URLSessionTransport.userAgent,
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
            "-audible_key", license.keyHex,
            "-audible_iv", license.ivHex
        ]
        // A place in the file, or nothing. A player that reports an unknown
        // position gives NaN, and "-ss nan" stops ffmpeg before it starts.
        if offset.isFinite, offset > 1, offset < 60 * 60 * 24 * 30 {
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
            // Every output path is absolute. The header file's path is
            // otherwise resolved against the working directory, which is not
            // the folder the segments go in, and ffmpeg stops before it
            // writes anything.
            "-hls_fmp4_init_filename", "init.mp4",
            "-hls_segment_filename", folder.appendingPathComponent("segment%05d.m4s").path,
            folder.appendingPathComponent("stream.m3u8").path
        ]
        return arguments
    }

    /// Waits until enough of the stream exists for the player to start.
    private func waitForFirstSegments(
        playlist: URL,
        process: Process,
        errors: Pipe
    ) async throws {
        let began = Date()
        while Date().timeIntervalSince(began) < StreamService.startDeadline {
            if !process.isRunning {
                let text = String(
                    data: errors.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
                throw AudibleError.downloadFailed(
                    text.isEmpty ? "The stream stopped before it started." : text)
            }
            let folder = playlist.deletingLastPathComponent()
            let segments = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
                .filter { $0.hasSuffix(".m4s") } ?? []
            // The playlist names the header file, so the player needs that too
            // before it can start.
            let hasHeader = FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("init.mp4").path)
            if FileManager.default.fileExists(atPath: playlist.path),
               hasHeader,
               segments.count >= StreamService.segmentsBeforeStart {
                Log.write(String(
                    format: "Stream ready after %.1fs.", Date().timeIntervalSince(began)))
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        stop()
        throw AudibleError.downloadFailed(
            "The stream did not start within \(Int(StreamService.startDeadline)) seconds.")
    }
}
