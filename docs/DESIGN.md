# AudibleKit — Design

Date: 2026-08-19
Repo: `audible-kit`
License: MIT
Platform: macOS 14+, Swift 6.2, SwiftPM

## Purpose

AudibleKit is a Swift client for the Audible API. It registers a device, signs
requests, lists the account library, obtains content licenses, downloads AAXC
files, decrypts them to M4B, and reads and writes playback positions.

The package has no user interface and no macOS UI dependencies. The Earmark app
is the first consumer. Other applications can use the package on its own.

## Provenance

AudibleKit is a clean-room implementation. Two projects implement the same
protocol and are copyleft: Libation (GPL-3.0, C#) and mkb79/audible (AGPL-3.0,
Python). No code comes from either project.

The implementation comes from the wire protocol: endpoint paths, header names,
the signature format, the request and response bodies, and the voucher crypto.
Protocol facts are not copyrightable. Network captures of the official clients
are the primary reference.

Rule for all contributors: do not copy code from Libation or mkb79/audible into
this repository.

## Module structure

Each type below is one file. Each has one purpose and a small public interface.

| Type | Purpose |
|---|---|
| `AudibleMarketplace` | Country to domain and marketplace ID. Static data. |
| `DeviceRegistration` | Turns an authorization code into a device identity. |
| `DeviceIdentity` | The stored credentials. Codable. Keychain-backed. |
| `RequestSigner` | Signs one URLRequest with the device private key. |
| `AudibleClient` | Sends signed requests. Decodes responses. Refreshes tokens. |
| `LibraryService` | Lists and searches the account library. |
| `LicenseService` | Requests a content license. Decrypts the voucher. |
| `DownloadService` | Downloads an AAXC file with progress reporting. |
| `DecryptService` | Runs ffmpeg to produce an M4B. |
| `PositionService` | Reads and writes last-heard positions. |

`AudibleClient` is the only type that performs network calls. The services take
a client and hold no transport logic of their own. This keeps every service
testable against a stub client.

## Authentication

Audible has no password API. Registration uses the Amazon sign-in page once.

1. The consumer application shows the Amazon sign-in page and captures the
   redirect that carries an `openid.oa2.authorization_code`. AudibleKit builds
   the sign-in URL and parses the redirect. It does not display anything.
2. `DeviceRegistration` posts the code plus a generated device serial to
   `POST https://api.amazon.<tld>/auth/register`.
3. The response yields the values stored in `DeviceIdentity`:
   `adp_token`, `device_private_key` (PEM RSA), `access_token`,
   `refresh_token`, `device_serial_number`, `customer_id`, `marketplace`.
4. `DeviceIdentity` is written to the macOS Keychain as one item. The private
   key never leaves the Keychain-backed store and never appears in logs.

Registration happens once per machine. The device appears in the account's
device list under a name the consumer application supplies.

## Request signing

Every call to `api.audible.<tld>` carries three headers:

- `x-adp-token` — the stored ADP token
- `x-adp-alg` — `SHA256withRSA:1.0`
- `x-adp-signature` — `<base64 signature>:<ISO 8601 timestamp>`

The signed payload joins these with newlines, in order: HTTP method, path with
query, timestamp, request body, ADP token. The signature is RSA PKCS#1 v1.5
over SHA-256, produced with the device private key. CryptoKit and Security
framework cover this; no third-party crypto dependency.

Signature construction is the highest-risk part of the port. It fails with an
opaque 401 when any element is wrong. It is therefore built and verified first,
before any other service exists.

## Library

`GET /1.0/library` with `response_groups` selecting product details, series,
contributors, and product images. Results paginate; `LibraryService` returns an
async sequence so the consumer can render as pages arrive.

Search and filtering run locally against the fetched library. The account
library is small enough that server-side search adds latency without benefit.

## License and download

1. `POST /1.0/content/{asin}/licenserequest` with a body naming the DRM types,
   quality, and `consumption_type: Download`.
2. The response carries `content_license` with a download URL and an encrypted
   `license_response` blob.
3. The blob decrypts with a key and IV derived from the device serial number.
   The plaintext yields the AAXC content `key` and `iv`.
4. `DownloadService` fetches the AAXC file. It uses a background `URLSession`
   so transfers continue when the application is not frontmost, and resumes
   from partial data after a network failure.
5. `DecryptService` runs ffmpeg:
   `ffmpeg -audible_key <key> -audible_iv <iv> -i in.aaxc -c copy out.m4b`
   The stream copies; there is no re-encode and no quality loss. Chapter marks
   and cover art carry over.
6. The voucher, the key, and the IV are discarded once the M4B verifies. The
   AAXC file is deleted.

Verification before deletion: ffprobe reports a duration within one second of
the duration the library reported for that ASIN.

ffmpeg is required at `/opt/homebrew/bin/ffmpeg` or on `PATH`. AudibleKit
reports a clear error when it is absent. It is invoked as a separate process
and is not linked, so its license does not reach this package.

## Positions

`PositionService` reads with `GET /1.0/annotations/lastpositions` for a set of
ASINs, and writes the current position back. Positions are milliseconds from
the start of the title.

Write policy, to protect the phone's position:

- Write on pause, on chapter change, and every 30 seconds during playback.
- Before writing, read the server position. When the server position is ahead
  of the local one by more than 60 seconds, and the local session started
  before that server write, keep the server position and tell the consumer.
  This stops a stale desktop session from rewinding the phone.

The exact write endpoint and body need confirmation by capture before this
service is written. Nothing else in the package depends on it.

## Errors

One public `AudibleError` enum. Every case names a cause and a recovery:
`notRegistered`, `registrationFailed`, `signatureRejected`, `tokenExpired`,
`licenseDenied`, `downloadFailed`, `ffmpegMissing`, `decryptFailed`,
`rateLimited`. Expired access tokens refresh once and retry once; a second
failure surfaces as `tokenExpired`.

## Testing

- Signing: fixed key, fixed timestamp, fixed request, known-good signature.
  Pure unit test, no network.
- Voucher decrypt: recorded blob, known plaintext.
- Services: stub `AudibleClient` returning recorded JSON. Covers pagination,
  empty library, missing fields, and each error case.
- Integration: one opt-in test against a real account, off by default, driven
  by an environment variable. It never runs in CI.

No recorded fixture contains a real token, key, or customer ID. A pre-commit
check greps for the credential field names.

## Out of scope

Podcasts, Audible Plus streaming, purchases, reviews, and social features. The
package covers owned titles only.
