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

// The same store the application uses, so the tool needs no separate sign-in
// and asks for nothing.
let store = MigratingCredentialStore()

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

/// Tries several license request shapes and reports what each returns.
///
/// The server chooses the delivery format from what the client says it
/// supports. Which combination yields the modern format is not documented.
func probeLicenseShapes(asin: String) async {
    let client = makeClient()
    let shapes: [(String, [String: Any])] = [
        ("Mpeg+Adrm, High", [
            "supported_drm_types": ["Mpeg", "Adrm"], "quality": "High"]),
        ("Adrm only, High", [
            "supported_drm_types": ["Adrm"], "quality": "High"]),
        ("Mpeg only, High", [
            "supported_drm_types": ["Mpeg"], "quality": "High"]),
        ("Mpeg+Adrm, Extreme", [
            "supported_drm_types": ["Mpeg", "Adrm"], "quality": "Extreme"]),
        ("Adrm, Extreme, adaptive", [
            "supported_drm_types": ["Adrm"], "quality": "Extreme",
            "use_adaptive_bit_rate": true]),
        ("Adrm, High, spatial off", [
            "supported_drm_types": ["Adrm"], "quality": "High",
            "spatial": false, "use_adaptive_bit_rate": false])
    ]

    for (name, extra) in shapes {
        var body: [String: Any] = [
            "consumption_type": "Download",
            "response_groups": "content_reference"
        ]
        for (key, value) in extra { body[key] = value }

        do {
            let data = try await client.send(
                method: "POST",
                path: "content/\(asin)/licenserequest",
                body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let license = root?["content_license"] as? [String: Any] ?? [:]
            let reference = (license["content_metadata"] as? [String: Any])?["content_reference"]
                as? [String: Any] ?? [:]
            let url = ((license["content_metadata"] as? [String: Any])?["content_url"]
                as? [String: Any])?["offline_url"] as? String ?? ""
            print("\(name.padding(toLength: 26, withPad: " ", startingAt: 0)) "
                  + "drm=\(license["drm_type"] as? String ?? "-") "
                  + "format=\(reference["content_format"] as? String ?? "-") "
                  + "ext=\(URL(string: url)?.pathExtension ?? "-")")
        } catch {
            print("\(name.padding(toLength: 26, withPad: " ", startingAt: 0)) failed: \(error.localizedDescription)")
        }
    }
}

/// Prints the whole license response, with the voucher removed.
///
/// The response carries more than one way to reach the audio, and which one is
/// usable is not obvious from the client side.
func dumpLicenseResponse(asin: String) async {
    let client = makeClient()
    let body: [String: Any] = [
        "supported_drm_types": ["Mpeg", "Adrm"],
        "quality": "High",
        "consumption_type": "Download",
        "response_groups": "last_position_heard,content_reference,chapter_info"
    ]
    do {
        let data = try await client.send(
            method: "POST",
            path: "content/\(asin)/licenserequest",
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var license = root["content_license"] as? [String: Any]
        else {
            fail("The response held no license.")
        }
        license["license_response"] = "REMOVED"
        root["content_license"] = license
        let pretty = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        print(String(data: pretty, encoding: .utf8) ?? "unreadable")
    } catch {
        fail(error.localizedDescription)
    }
}

/// Prints what a license returns, and checks that the file can be fetched.
///
/// This exists because a download that fails inside ffmpeg says only that the
/// server refused it, without saying how the request differed.
func describeLicense(asin: String) async {
    let client = makeClient()
    do {
        let license = try await LicenseService(client: client).license(for: asin)
        print("asin:      \(asin)")
        print("url host:  \(license.downloadURL.host ?? "none")")
        print("url path:  \(license.downloadURL.path)")
        print("format:    \(license.downloadURL.pathExtension)")
        print("chapters:  \(license.chapters.count)")
        print("key bytes: \(license.key.count), iv bytes: \(license.iv.count)")
        print("full url:  \(license.downloadURL.absoluteString)")
    } catch {
        fail(error.localizedDescription)
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
case "license":
    guard arguments.count > 1 else { fail("Give an ASIN.") }
    await describeLicense(asin: arguments[1])
case "raw":
    guard arguments.count > 1 else { fail("Give an ASIN.") }
    await dumpLicenseResponse(asin: arguments[1])
case "probe":
    guard arguments.count > 1 else { fail("Give an ASIN.") }
    await probeLicenseShapes(asin: arguments[1])
case "logout":
    try? store.clear()
    print("Credentials cleared.")
default:
    print("""
    audible-cli register [country]     Register this Mac with Audible
    audible-cli library                List every owned title
    audible-cli positions              Show where each title was left
    audible-cli download <ASIN> [dir]  Download and decrypt one title
    audible-cli license <ASIN>         Show what a license returns
    audible-cli logout                 Forget the stored credentials
    """)
}
