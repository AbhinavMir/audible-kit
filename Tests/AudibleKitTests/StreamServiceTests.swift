import Foundation
import Testing
@testable import AudibleKit

@Suite("Streaming")
struct StreamServiceTests {

    static let license = ContentLicense(
        asin: "B0TEST0001",
        downloadURL: URL(string: "https://example.invalid/audio.aaxc?token=abc")!,
        key: Data(repeating: 0xAB, count: 16),
        iv: Data(repeating: 0xCD, count: 16),
        chapters: [],
        lastPositionHeard: nil)

    @Test("The stream reads from the network and copies the audio")
    func argumentsUseTheRemoteFile() {
        let arguments = StreamService.arguments(for: Self.license, from: 0)
        #expect(arguments.contains("https://example.invalid/audio.aaxc?token=abc"))
        // Copying rather than re-encoding keeps the stream cheap and lossless.
        #expect(arguments.contains("copy"))
        #expect(arguments.contains("-audible_key"))
        #expect(arguments.contains(Self.license.keyHex))
    }

    @Test("A stream from the start does not ask ffmpeg to seek")
    func noSeekAtStart() {
        #expect(!StreamService.arguments(for: Self.license, from: 0).contains("-ss"))
    }

    @Test("A stream from a position seeks before opening the input")
    func seeksBeforeInput() {
        // Placed before -i, ffmpeg fetches only the part it needs rather than
        // reading the whole file up to that point.
        let arguments = StreamService.arguments(for: Self.license, from: 3600)
        let seek = try! #require(arguments.firstIndex(of: "-ss"))
        let input = try! #require(arguments.firstIndex(of: "-i"))
        #expect(seek < input)
        #expect(arguments[seek + 1] == "3600.000")
    }

    @Test("Segments are short enough to start quickly")
    func segmentLength() {
        #expect(StreamService.segmentSeconds <= 10)
        let arguments = StreamService.arguments(for: Self.license, from: 0)
        let time = try! #require(arguments.firstIndex(of: "-hls_time"))
        #expect(arguments[time + 1] == String(StreamService.segmentSeconds))
    }

    @Test("The server serves the playlist with the type players expect")
    func playlistContentType() {
        #expect(LocalMediaServer.contentType(for: "stream.m3u8")
                == "application/vnd.apple.mpegurl")
        #expect(LocalMediaServer.contentType(for: "segment00001.m4s") == "audio/mp4")
    }

    @Test("The server refuses a name that reaches outside its folder")
    func rejectsPathEscape() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("playlist".utf8).write(to: folder.appendingPathComponent("stream.m3u8"))

        let server = try LocalMediaServer(directory: folder)
        try await server.start()
        defer { server.stop() }

        let allowed = try await String(
            contentsOf: server.url(for: "stream.m3u8"), encoding: .utf8)
        #expect(allowed == "playlist")

        // A traversal attempt must not reach the file below.
        var request = URLRequest(url: URL(
            string: "http://127.0.0.1:\(server.port)/../../etc/hosts")!)
        request.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode != 200)
    }
}
