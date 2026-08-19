import Foundation
import AudibleKit

/// A small tool that exercises AudibleKit against a real account.
///
/// It exists to prove registration, signing, licensing, and download work
/// before any user interface depends on them.
///
///     audible-cli register [country]
///     audible-cli library
///     audible-cli positions
///     audible-cli download <ASIN> [directory]
///     audible-cli logout

let store = KeychainCredentialStore()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(1)
}

func makeClient() -> AudibleClient {
    do {
        return try AudibleClient(store: store)
    } catch AudibleError.notRegistered {
        fail("This device is not registered. Run: audible-cli register")
    } catch {
        fail(error.localizedDescription)
    }
}

func format(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

// MARK: Commands

func register(country: String) async {
    guard let marketplace = AudibleMarketplace.named(country) else {
        fail("Unknown country '\(country)'. Known: "
             + AudibleMarketplace.all.map(\.countryCode).joined(separator: ", "))
    }

    let registration = DeviceRegistration(marketplace: marketplace)
    let attempt = registration.signInAttempt()

    print("""

    1. Open this URL in a browser and sign in to Amazon:

    \(attempt.url.absoluteString)

    2. After sign-in the page will fail to load. That is expected.
    3. Copy the full address of that failed page and paste it here.

    """)
    print("Redirect URL: ", terminator: "")
    guard let line = readLine(strippingNewline: true), let url = URL(string: line) else {
        fail("That is not a URL.")
    }
    guard let code = DeviceRegistration.authorizationCode(in: url) else {
        fail("That address carries no authorization code. Sign in again.")
    }

    do {
        let name = "Earmark on \(ProcessInfo.processInfo.hostName)"
        let identity = try await registration.register(
            code: code, attempt: attempt, deviceName: name)
        try store.save(identity)
        print("Registered. \(identity)")
    } catch {
        fail(error.localizedDescription)
    }
}

func showLibrary() async {
    let service = LibraryService(client: makeClient())
    do {
        let books = try await service.all()
        print("\(books.count) titles\n")
        for book in books {
            let length = book.duration.map(format) ?? "unknown length"
            print("\(book.asin)  \(book.title)")
            print("            \(book.authorLine.isEmpty ? "no author listed" : book.authorLine)"
                  + "  ·  \(length)\(book.isFinished ? "  ·  finished" : "")")
        }
    } catch {
        fail(error.localizedDescription)
    }
}

func showPositions() async {
    let client = makeClient()
    do {
        let books = try await LibraryService(client: client).all()
        let positions = try await PositionService(client: client)
            .positions(for: books.map(\.asin))
        let started = books.filter { positions[$0.asin] != nil }
        print("\(started.count) titles with a recorded position\n")
        for book in started {
            guard let position = positions[book.asin] else { continue }
            print("\(format(position.position))  \(book.title)")
        }
    } catch {
        fail(error.localizedDescription)
    }
}

func download(asin: String, directory: String) async {
    let client = makeClient()
    do {
        let book = try await LibraryService(client: client).book(asin: asin)
        print("\(book.title)")

        let license = try await LicenseService(client: client).license(for: asin)
        print("License granted. \(license.chapters.count) chapters.")

        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let encrypted = folder.appendingPathComponent("\(asin).aaxc")
        let decrypted = folder.appendingPathComponent("\(book.title.fileSafe).m4b")

        let reporter = ProgressReporter()
        try await DownloadService().download(license, to: encrypted) { progress in
            reporter.report(progress)
        }
        FileHandle.standardError.write(Data("\n".utf8))

        print("Decrypting...")
        try await DecryptService().decrypt(
            encrypted, license: license, to: decrypted, expectedDuration: book.duration)
        try? FileManager.default.removeItem(at: encrypted)
        print("Wrote \(decrypted.path)")
    } catch {
        fail(error.localizedDescription)
    }
}

/// Prints whole percentages as they change. The download callback runs off the
/// main actor, so the last printed value is held behind a lock.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1

    func report(_ progress: DownloadService.Progress) {
        guard let fraction = progress.fraction else { return }
        let percent = Int(fraction * 100)
        let shouldPrint = lock.withLock {
            guard percent > lastPercent else { return false }
            lastPercent = percent
            return true
        }
        if shouldPrint {
            FileHandle.standardError.write(Data("\rDownloading \(percent)%".utf8))
        }
    }
}

extension String {
    /// The title with characters that a file name cannot hold removed.
    var fileSafe: String {
        components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
    }
}

// MARK: Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "register":
    await register(country: arguments.count > 1 ? arguments[1] : "us")
case "library":
    await showLibrary()
case "positions":
    await showPositions()
case "download":
    guard arguments.count > 1 else { fail("Give an ASIN to download.") }
    await download(
        asin: arguments[1],
        directory: arguments.count > 2 ? arguments[2] : FileManager.default.currentDirectoryPath)
case "logout":
    try? store.clear()
    print("Credentials cleared.")
default:
    print("""
    audible-cli register [country]     Register this Mac with Audible
    audible-cli library                List every owned title
    audible-cli positions              Show where each title was left
    audible-cli download <ASIN> [dir]  Download and decrypt one title
    audible-cli logout                 Forget the stored credentials
    """)
}
