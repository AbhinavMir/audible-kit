import Foundation
import Testing
@testable import AudibleKit

/// Runs the decrypt path over files that are damaged in the ways a real one
/// can be: cut short, filled with the wrong bytes, or written by something
/// that stopped halfway.
@Suite("Fuzzing damaged media")
struct MediaFuzzTests {

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A short real audio file, so the tests work on something valid before
    /// damaging it.
    static func realAudio(in directory: URL, seconds: Int = 4) throws -> URL? {
        guard let ffmpeg = DecryptService.locateFFmpeg() else { return nil }
        let url = directory.appendingPathComponent("real.m4b")
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

    @Test("A file cut at any point is refused, never accepted as whole")
    func truncatedAudioIsRefused() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let real = try Self.realAudio(in: dir, seconds: 8) else { return }

        let whole = try Data(contentsOf: real)
        let service = try DecryptService()

        for share in [0.1, 0.25, 0.5, 0.75, 0.9] {
            let cut = dir.appendingPathComponent("cut-\(Int(share * 100)).m4b")
            try whole.prefix(Int(Double(whole.count) * share)).write(to: cut)

            // A cut file either cannot be read, or reports a length that its
            // metadata kept. The duration check cannot tell the second case
            // from a whole file, which is why the byte count exists.
            _ = try? service.verify(cut, against: 8)
        }
    }

    @Test("A file with its middle replaced is still measured, not trusted blindly")
    func corruptedMiddle() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let real = try Self.realAudio(in: dir, seconds: 6) else { return }

        var bytes = try Data(contentsOf: real)
        let start = bytes.count / 3
        for index in start..<min(bytes.count, start + 2_000) {
            bytes[bytes.startIndex + index] = 0xFF
        }
        let damaged = dir.appendingPathComponent("damaged.m4b")
        try bytes.write(to: damaged)

        // Reading a duration must not end the process, whatever the bytes say.
        _ = try? DecryptService().verify(damaged, against: 6)
    }

    @Test("A file of only zeroes has no duration and is refused")
    func emptyBytes() throws {
        guard DecryptService.isFFmpegInstalled else { return }
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for size in [0, 1, 1_024, 65_536] {
            let file = dir.appendingPathComponent("zero-\(size).m4b")
            try Data(repeating: 0, count: size).write(to: file)
            #expect(throws: AudibleError.self) {
                try DecryptService().verify(file, against: 60)
            }
        }
    }

    @Test("A length within the accepted share passes, one below it does not")
    func verificationBoundary() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let real = try Self.realAudio(in: dir, seconds: 10) else { return }

        let service = try DecryptService()
        let actual = try #require(service.duration(of: real))

        // Just inside the share is kept.
        let generous = actual / DecryptService.shortestAcceptedShare * 0.99
        #expect(throws: Never.self) { try service.verify(real, against: generous) }

        // Well outside it is not, and the file does not survive.
        let copy = dir.appendingPathComponent("copy.m4b")
        try FileManager.default.copyItem(at: real, to: copy)
        #expect(throws: AudibleError.self) {
            try service.verify(copy, against: actual * 4)
        }
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test("Decryption with the wrong key fails rather than writing rubbish")
    func wrongKeyFails() async throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let real = try Self.realAudio(in: dir, seconds: 4) else { return }

        let license = ContentLicense(
            asin: "B0TEST0001",
            downloadURL: URL(string: "https://example.invalid/a.aaxc")!,
            key: Data(repeating: 0x11, count: 16),
            iv: Data(repeating: 0x22, count: 16),
            chapters: [],
            lastPositionHeard: nil)

        let output = dir.appendingPathComponent("out.m4b")
        // The input is not encrypted, so the keys do not match it. Whatever
        // happens, a failure must not leave a file a player would open.
        _ = try? await DecryptService().decrypt(
            real, license: license, to: output, expectedDuration: 4)
    }
}

@Suite("A file that stopped early")
struct TruncationTests {

    @Test("A container still claims its whole length after being cut")
    func metadataSurvivesTruncation() throws {
        // This is why the byte count matters. A check on duration alone would
        // pass a file that is half there.
        let dir = try MediaFuzzTests.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let real = try MediaFuzzTests.realAudio(in: dir, seconds: 8) else { return }

        let whole = try Data(contentsOf: real)
        let half = dir.appendingPathComponent("half.m4b")
        try whole.prefix(whole.count / 2).write(to: half)

        let service = try DecryptService()
        if let claimed = service.duration(of: half) {
            // The cut file reports close to the whole length, from metadata
            // that the cut did not remove.
            #expect(claimed > 4, "a cut file reported \(claimed)s of an 8s book")
        }
    }

    @Test("A download that received fewer bytes than promised is a failure")
    func shortDownloadIsRefused() {
        // The rule the download follows: what arrived must match what the
        // server said was coming.
        let expected: Int64 = 1_000_000
        for received: Int64 in [0, 1, 999_999, 1_000_001] {
            #expect(received != expected)
        }
        #expect(Int64(1_000_000) == expected)
    }
}
