import Foundation
import Testing
@testable import AudibleKit

@Suite("Decryption")
struct DecryptServiceTests {

    /// Writes a short silent M4B with ffmpeg so the duration checks have a
    /// real file to read. Returns nil when ffmpeg is not installed.
    static func makeFixtureAudio(seconds: Int) throws -> URL? {
        guard let ffmpeg = DecryptService.locateFFmpeg() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiblekit-fixture-\(seconds)s.m4b")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "anullsrc=r=22050:cl=mono",
            "-t", String(seconds), "-c:a", "aac", url.path
        ]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? url : nil
    }

    @Test("ffmpeg is found when it is installed")
    func findsFFmpeg() throws {
        let located = DecryptService.locateFFmpeg()
        #expect(located == nil || FileManager.default.isExecutableFile(atPath: located!.path))
        #expect(DecryptService.isFFmpegInstalled == (located != nil))
    }

    @Test("A missing ffmpeg is reported, not worked around")
    func reportsMissingFFmpeg() {
        #expect(throws: AudibleError.self) {
            _ = try DecryptService(ffmpegURL: URL(fileURLWithPath: "/nowhere/ffmpeg"))
                .verify(URL(fileURLWithPath: "/nowhere/file.m4b"), against: 10)
        }
    }

    @Test("A file's duration is read back")
    func readsDuration() throws {
        guard let file = try Self.makeFixtureAudio(seconds: 5) else { return }
        let service = try DecryptService()
        let duration = try #require(service.duration(of: file))
        #expect(abs(duration - 5) < 1)
    }

    @Test("A file matching the expected length passes verification")
    func acceptsMatchingDuration() throws {
        guard let file = try Self.makeFixtureAudio(seconds: 5) else { return }
        try DecryptService().verify(file, against: 5)
    }

    @Test("A truncated file is rejected and deleted")
    func rejectsAndDeletesShortFile() throws {
        guard let source = try Self.makeFixtureAudio(seconds: 5) else { return }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiblekit-truncated.m4b")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: source, to: copy)

        #expect(throws: AudibleError.self) {
            try DecryptService().verify(copy, against: 3600)
        }
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }
}
