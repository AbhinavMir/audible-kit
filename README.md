# AudibleKit

A Swift client for the Audible API. It registers a device, signs requests,
lists an account's library, obtains content licenses, downloads titles, and
decrypts them to plain M4B files. It also reads and writes the playback
position that the Audible mobile application uses.

The package covers titles the account owns. It exists so that a person can
listen to their own audiobooks in a player of their choosing.

## Requirements

- macOS 14 or later
- Swift 6.0 or later
- `ffmpeg`, for the decryption step: `brew install ffmpeg`

## Install

```swift
.package(url: "https://github.com/AbhinavMir/audible-kit", from: "0.1.0")
```

## Use

Registration needs an authorization code from the Amazon sign-in page. Build
the sign-in URL, show it, and read the code out of the page it lands on.

```swift
let registration = DeviceRegistration(marketplace: .us)
let attempt = registration.signInAttempt()
// Show attempt.url, then catch the redirect:
guard let code = DeviceRegistration.authorizationCode(in: redirectURL) else { return }

let identity = try await registration.register(
    code: code, attempt: attempt, deviceName: "Earmark on my Mac")
try KeychainCredentialStore().save(identity)
```

Afterwards every service works from the stored identity.

```swift
let client = try AudibleClient(store: KeychainCredentialStore())

let books = try await LibraryService(client: client).all()

let license = try await LicenseService(client: client).license(for: books[0].asin)
try await DownloadService().download(license, to: encryptedURL)
try await DecryptService().decrypt(
    encryptedURL, license: license, to: outputURL,
    expectedDuration: books[0].duration)

let positions = try await PositionService(client: client)
    .positions(for: books.map(\.asin))
```

## Command-line tool

The package ships a small tool that exercises every path against a real
account. Use it to confirm the client works before building on it.

```
swift run audible-cli register us
swift run audible-cli library
swift run audible-cli positions
swift run audible-cli download B0TEST0001 ~/Audiobooks
```

## Design notes

`AudibleClient` is the only type that touches the network. Every service takes
a client, so each one tests against a stub transport with no network at all.

Credentials live in the macOS Keychain as one JSON item, so a partial write
cannot leave a key without its matching token. No fixture in this repository
contains a real token, key, or customer identifier.

A field the server does not send stays absent. A title with no reported
runtime keeps a nil duration rather than claiming zero, and a title with no
recorded position is missing from the result rather than sitting at the start.

## Provenance

This is a clean-room implementation written from the wire protocol. Two other
projects implement the same protocol and are worth knowing about:

- [Libation](https://github.com/rmcrackan/Libation), GPL-3.0, C#
- [mkb79/audible](https://github.com/mkb79/Audible), AGPL-3.0, Python

No code comes from either. Do not copy code from them into this repository:
both are copyleft, and this package is MIT.

## Status

Registration, signing, library listing, licensing, download, decryption, and
position reads are implemented and unit tested. The position **write** endpoint
still needs confirmation against a live account.

## License

MIT. See `LICENSE`.
