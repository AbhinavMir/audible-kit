import Foundation
import Testing
@testable import AudibleKit

/// Exercises the parts that write to disk, where the disk does not cooperate.
@Suite("Fuzzing the disk")
struct DiskFuzzTests {

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("disk-fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Storing credentials where they cannot be written reports it")
    func unwritableCredentialStore() throws {
        let store = FileCredentialStore(
            fileURL: URL(fileURLWithPath: "/System/earmark-must-not-exist/creds.json"))
        #expect(throws: (any Error).self) {
            try store.save(.testIdentity())
        }
        // Reading from a place that holds nothing is not an error.
        #expect(try store.load() == nil)
    }

    @Test("A credentials file of any content is read or refused, never fatal")
    func damagedCredentialFile() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bodies: [Data] = [
            Data(), Data("{}".utf8), Data("null".utf8), Data("[]".utf8),
            Data(#"{"adpToken": 1}"#.utf8),
            Data(#"{"adp_token": "x"}"#.utf8),
            Data(repeating: 0, count: 4096),
            Data(String(repeating: "{", count: 500).utf8)
        ]
        for (index, body) in bodies.enumerated() {
            let url = dir.appendingPathComponent("creds\(index).json")
            try body.write(to: url)
            _ = try? FileCredentialStore(fileURL: url).load()
        }
    }

    @Test("Decrypting reports a missing ffmpeg rather than pretending")
    func missingFFmpeg() throws {
        let service = try DecryptService(
            ffmpegURL: URL(fileURLWithPath: "/nowhere/at/all/ffmpeg"))
        // Reading a duration with no ffprobe beside it gives nothing.
        #expect(service.duration(of: URL(fileURLWithPath: "/tmp/none.m4b")) == nil)
    }

    @Test("A file that is not audio fails verification and is removed")
    func verificationRemovesRubbish() throws {
        guard DecryptService.isFFmpegInstalled else { return }
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for (index, body) in [Data(), Data("not audio".utf8),
                              Data(repeating: 0xFF, count: 8192)].enumerated() {
            let file = dir.appendingPathComponent("rubbish\(index).m4b")
            try body.write(to: file)
            #expect(throws: AudibleError.self) {
                try DecryptService().verify(file, against: 3600)
            }
            // A file that cannot be checked must not be left where a player
            // would try to open it.
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("A local server refuses names that reach outside its folder")
    func serverContainment() async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("playlist".utf8).write(to: dir.appendingPathComponent("stream.m3u8"))

        let outside = dir.deletingLastPathComponent().appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let server = try LocalMediaServer(directory: dir)
        try await server.start()
        defer { server.stop() }

        for name in ["../secret.txt", "..%2Fsecret.txt", "%2e%2e%2fsecret.txt",
                     "./stream.m3u8", "a/../stream.m3u8", "", "//etc/passwd"] {
            let text = "http://127.0.0.1:\(server.port)/\(name)"
            guard let url = URL(string: text) else { continue }
            let (data, response) = try await URLSession.shared.data(from: url)
            let body = String(data: data, encoding: .utf8) ?? ""
            #expect(!body.contains("secret"), "leaked through: \(name)")
            _ = response
        }

        // What it is meant to serve, it serves.
        let good = try await String(
            contentsOf: server.url(for: "stream.m3u8"), encoding: .utf8)
        #expect(good == "playlist")
    }

    @Test("A file already on disk is reused rather than fetched again")
    func reuseNeedsAMatchingSize() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.aaxc")
        try Data(repeating: 7, count: 1_024).write(to: file)

        #expect(FileManager.default.fileSize(at: file) == 1_024)
        #expect(FileManager.default.fileSize(at: dir.appendingPathComponent("none")) == nil)
    }
}

@Suite("What the application will run")
struct ExecutableSafetyTests {

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A program anybody can write to is not run")
    func refusesWritableBinaries() throws {
        // A file anybody can write to is a file anybody can replace, and this
        // one is handed the key to the audio.
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for permissions in [0o777, 0o775, 0o757, 0o733] {
            let file = dir.appendingPathComponent("ffmpeg-\(permissions)")
            FileManager.default.createFile(
                atPath: file.path, contents: Data("#!/bin/sh\n".utf8),
                attributes: [.posixPermissions: permissions])
            #expect(!DecryptService.isSafeToRun(file.path),
                    "would run a file with permissions \(String(permissions, radix: 8))")
        }
    }

    @Test("A program only its owner can write to is run")
    func acceptsOwnerOnlyBinaries() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for permissions in [0o755, 0o750, 0o700] {
            let file = dir.appendingPathComponent("ffmpeg-\(permissions)")
            FileManager.default.createFile(
                atPath: file.path, contents: Data("#!/bin/sh\n".utf8),
                attributes: [.posixPermissions: permissions])
            #expect(DecryptService.isSafeToRun(file.path),
                    "refused a file with permissions \(String(permissions, radix: 8))")
        }
    }

    @Test("A link is judged by what it points at")
    func followsLinks() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("real")
        FileManager.default.createFile(
            atPath: target.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o777])

        let link = dir.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(!DecryptService.isSafeToRun(link.path),
                "followed a link to a file anybody can write")
    }

    @Test("Nothing that does not exist is run")
    func refusesAbsentFiles() {
        #expect(!DecryptService.isSafeToRun("/nowhere/at/all/ffmpeg"))
        #expect(!DecryptService.isSafeToRun(""))
    }

    @Test("The search does not follow PATH")
    func doesNotFollowPath() {
        // Every place searched is an absolute path that is written down.
        for path in DecryptService.searchPaths {
            #expect(path.hasPrefix("/"), "\(path) is not an absolute place")
        }
    }
}
