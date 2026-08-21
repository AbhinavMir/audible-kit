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

To play without downloading, stream instead. ffmpeg reads the encrypted file
over the network, decrypts it, and writes HLS segments that a local server
hands to the player. Nothing large is stored.

```swift
let service = try StreamService()
let stream = try await service.start(license, from: 3600)
// Hand stream.playlistURL to AVPlayer. Its zero is stream.startOffset.
service.stop()  // Deletes every segment it wrote.
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

Collections are the only organisation Audible itself stores, so a shelf made
here appears in the mobile application.

```swift
let collections = CollectionService(client: client)
let reading = try await collections.create(name: "Reading")
try await collections.add(["B0TEST0001"], to: reading.id)
let asins = try await collections.items(in: reading.id)
try await collections.remove("B0TEST0001", from: reading.id)
try await collections.delete(reading.id)
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

## Scope

This package talks to Audible with an account holder's own credentials, and
reaches only the titles that account already owns. It is meant for listening to
your own library in a player of your choosing.

It is not a way to obtain audiobooks. It cannot reach a title an account does
not own, and it produces no output that is any use to anyone but the account
holder.

Do not distribute audio it produces. That is somebody else's work.

## Provenance

This is a clean-room implementation written from the wire protocol. Two other
projects implement the same protocol and are worth knowing about:

- [Libation](https://github.com/rmcrackan/Libation), GPL-3.0, C#
- [mkb79/audible](https://github.com/mkb79/Audible), AGPL-3.0, Python

No code comes from either. Do not copy code from them into this repository:
both are copyleft, and this package is MIT.

## Status

Verified against a real account: device registration, request signing, library
listing, content licensing, voucher decryption, and a download of a 32-hour
title that decrypted to a playable M4B.

Streaming is verified against a real account: ffmpeg reads the encrypted file
over the network, decrypts it, and the resulting segments decode as AAC with
no errors.

Collections are verified against a real account: create, add eight titles,
list, remove them one at a time down to zero, rename, and delete.

What the API does not offer: there is no way to remove a title from a library,
and no recommendations, similar titles, or reviews for an account. A library is
append-only from a client's side, so anything else a person would call
management has to live in the client.

Position reads follow the documented endpoint. The position **write** endpoint
is implemented but has not been confirmed against a live account yet.

The package covers titles an account owns. Podcasts, Audible Plus streaming,
and purchases are out of scope.

## Notes for anyone reading the protocol code

Three parts are easy to get wrong, and each fails in a way that does not say
what is wrong:

- **The PKCE challenge** hashes the verifier *text*, not the bytes the text was
  built from. Hashing the wrong thing gives "one or more provided values are
  invalid".
- **The voucher key** is one SHA-256 over the device type, the device serial,
  the customer identifier, and the ASIN, in that order. Miss any one and the
  voucher will not open. The voucher is not padded.
- **The request signature** covers the method, the path with query, the
  timestamp, the body, and the ADP token, joined with newlines. A wrong
  signature returns a bare 401 with no explanation.
- **Removing a title from a collection puts the ASIN in the query**, as
  `DELETE .../items?asins=<asin>`. The same call with the ASIN in the path is
  refused, and with the ASIN in a body it fails inside the gateway. Adding a
  title with an `action` of `remove` adds it a second time.
- **Every request for audio must carry the Audible user agent.** The delivery
  network refuses any other client with 403 and the words "request blocked",
  however valid the signed URL is. ffmpeg's own agent is refused, so a stream
  must set `-user_agent`.

Each has a test that pins the behaviour.

## License

MIT. See `LICENSE`.
