# Port note: CmuxNextBrowserImport readers to cmux-browser-import

The Swift readers in
`Packages/macOS/CmuxNext/Sources/CmuxNextBrowserImport/Parsers/`, ported to Rust
(`plans/cmux-next/language-layers.md`, rule 7). The daemon serves them as one
operation, `browser_import.read` (`browser-import-v1`,
`cmux-tui-core/src/resource_router/browser_import.rs`); its `reader` field is
the "Op" column below. The port lands in two steps (`docs/ci/app-ffi-release.md`):
this crate and the op first, while the app keeps its Swift readers; then, after
the app FFI re-pin, the app calls the op through `BrowserDataReader`
(`CmuxNextBrowserImport/Import/BrowserDataReader.swift`) and
`BrowserImportClient`, and the Swift readers are deleted. Line counts are
`scripts/cmux-next/swift-logic-lines.py`'s `swift_logic_lines` at
feat-cmux-next 5ab993d99cca.

## Who may read, and which folders

`browser_import.read` is in `request_origin::USER_ONLY_OPERATIONS`: only the
verified app connection sends it, because it makes the daemon open a file by
path. An agent, a page or a paired client is refused with `origin.forbidden`.

The daemon outlives the app and the CLI can start it, so it may not hold the
app's Full Disk Access. It refuses every path under its home's
`Library/Safari`, `Library/SafariTechnologyPreview`, `Library/Containers` and
`Library/Group Containers` (`ops::PROTECTED`, as written and with links
resolved, any case), and any relative path or `..`. For a source there
(Safari, an app-container profile such as Aloha's), the app reads the files a
read opens (`ProtectedProfileUpload`, a fixed list pinned by
`ProtectedProfileUploadTests`) and sends their bytes, in 2 MiB chunks, into an
upload the daemon holds in memory (`upload.append`, `upload::Uploads`); the
read names the upload, and the app drops it after (`upload.drop`). Nothing of a
protected folder is ever written to disk, where any process of the same user
could read it: a database is opened in memory with its WAL replayed
(`sqlite::Snapshot::from_memory`). An upload holds at most 256 MiB (512 MiB for
all of them) and is refused with `tooLarge` past it; one idle for 5 minutes is
dropped. So an agent without Full Disk Access can never read a protected
profile by asking the daemon, and no copy of one is left for it to find.

## Parsers: ported

| Swift file (declaration) | Rust | Op | Logic lines |
| --- | --- | --- | ---: |
| `ArcSidebarReader.swift` | `arc::bookmarks` | `arc.bookmarks` | 81 |
| `BrowserTime.swift` (`BrowserTime`) | `time::{chromium, mozilla, cocoa}` | (in every reader) | 25 |
| `BrowserTime.swift` (`ImportableURL`) | `url::{importable, sql_filter}` | (in every reader) | 11 |
| `ChromiumBookmarksParser.swift` | `chromium::bookmarks` | `chromium.bookmarks` | 34 |
| `ChromiumExtensionsReader.swift` | `chromium::extensions` | `chromium.extensions` | 97 |
| `ChromiumHistoryReader.swift` | `chromium::history` | `chromium.history` | 21 |
| `ChromiumSearchEngineReader.swift` (`ImportedSearchEngine`) | `search::{setting, host}`, `model::SearchEngine` | `search_engine.setting` | 28 |
| `ChromiumSearchEngineReader.swift` (`ChromiumSearchEngineReader`) | `chromium::search_engine`, `search::{engine, clean}` | `chromium.search_engine` | 44 |
| `ChromiumSessionReader.swift` | `chromium::{session, session_file, latest_session_file}` | `chromium.session`, `chromium.session_file`, `chromium.latest_session_file` | 103 |
| `ExportedHistory.swift` | `exported::{parse, looks_like_history}` | `exported_history.parse`, `exported_history.looks_like` | 48 |
| `FirefoxPlacesReader.swift` | `firefox::{bookmarks, history}` | `firefox.bookmarks`, `firefox.history` | 65 |
| `FirefoxSearchEngineReader.swift` | `firefox::{search_engine, search_engine_json}` | `firefox.search_engine` | 42 |
| `FirefoxSessionReader.swift` | `firefox::{session, session_file}`, `lz4::decompress` | `firefox.session`, `firefox.session_file` | 54 |
| `PickleReader.swift` | `pickle::Pickle` | (in `chromium::session`) | 51 |
| `SQLiteSnapshot.swift` (`SQLiteSnapshot`, `SQLiteRow`) | `sqlite::{Snapshot, text, int64, double, blob}` | (in every database reader) | 69 + 17 |
| `SafariReaders.swift` (`SafariBookmarksParser`) | `safari::bookmarks` | `safari.bookmarks` | 39 |
| `SafariReaders.swift` (`SafariHistoryReader`) | `safari::history` | `safari.history` | 25 |
| `SafariSearchEngineReader.swift` | `safari::search_engine` | `safari.search_engine` | 12 |
| `WellKnownSearchEngines.swift` | `search::{WELL_KNOWN, well_known}` | (in the Firefox and Safari engines) | 22 |

All of `Parsers/`: 888 logic lines.

### What the Swift step deletes

- **777 lines**: every file above except `SQLiteSnapshot.swift` (86) and
  `BrowserTime.swift`'s `BrowserTime` (25). Those two stay until the cookie
  and password readers move: `ChromiumCookieReader`, `FirefoxCookieReader`,
  `ChromiumLoginDataReader`, `FirefoxLoginReader` and `FirefoxPasswordCrypto`
  open `SQLiteSnapshot`s, the cookie and login readers call `BrowserTime`, and
  `CmuxNextApp/Billing/BrowserProfileLinkSession.swift` opens one too.
- `ImportedSearchEngine` (28) becomes its four stored fields (a `Codable`
  decode target, as `ImportedBookmark` and friends already are); `setting`
  and `host` go to `search_engine.setting`.
- The Swift that replaces them (`BrowserDataReader`) is glue: one call per reader that encodes the
  request, decodes the reply with the existing `Codable` types
  (`ImportedBookmark`, `ImportedHistoryEntry`, `ImportedTab`,
  `ImportedExtension`, `ImportedSearchEngine`; the replies use their keys,
  omit nil fields and write dates as seconds since 2001, `JSONDecoder`'s
  default), and maps `{"error": {"kind"}}` to the thrown error. Safari's
  Search setting: the app reads `NSPreferredWebServices` from the global
  defaults domain and passes it as `services`.

### Behaviour notes

- URLs are the source's text. The Swift readers kept `URL(string:)`'s value;
  the app's `JSONDecoder` makes the same `URL(string:)` from the text, so the
  URL is identical. Only the scheme check (http, https, file, ftp, any case)
  is here. `ExportedHistory` merges rows per URL text where Swift merged per
  `URL` value; the two differ only for two spellings Foundation encodes to one
  URL (`a b` and `a%20b`).
- `search::clean` keeps a kept query item's text; `URLComponents.queryItems`
  re-encoded it, which differs only for an escape Foundation writes another
  way.
- Where Swift iterated a `Dictionary` (in no defined order), Rust uses a
  defined one: session tabs at the same window and index sort by tab id, the
  extension ids are sorted, `builtIn` is read in key order.
- `SQLiteSnapshot.query` checked `Task.checkCancellation()` every 256 rows.
  Each reader's query is bounded (`LIMIT`, at most `ImportPlan.defaultHistoryLimit`
  5000 rows for history), and a daemon request cannot see a Swift task; the
  app drops the result of a cancelled task.
- JSON casts follow Foundation's bridging (`src/json.rs`): `as? Int` takes an
  integral number or a boolean, `as? [[String: Any]]` is all or nothing.

## Passwords and Cookies: deferred

`Passwords/` (973 logic lines) and `Cookies/` (463) are not in this crate.

- **Firefox passwords need 3DES.** `FirefoxPasswordCrypto` opens older
  profiles' `key4.db` with PKCS#12 SHA-1 + 3DES-CBC, and their logins with
  3DES-CBC. No crate in the cmux-tui or app FFI lock files implements DES.
  Adding one (`des`, `cbc`, `pbkdf2`) is a new dependency and needs its own
  review; hand-writing DES is not a port to verify here.
- **Chromium cookies and passwords need AES-128-CBC.** `aes` 0.8 is in the
  cmux-tui lock (not the app FFI's), `cbc` is in neither, and `ring` has no
  CBC mode. PBKDF2-HMAC-SHA1 and SHA-256 map onto `ring`, but the cipher would
  be a hand-written CBC over `aes`'s block, plus `SecretBytes`' zeroizing
  memory across the process boundary (the key and every plaintext must never
  be a Rust `String` or a copy nobody wipes, and decrypted secrets would then
  cross the daemon socket). That is a design for its own
  PR, with test vectors from real Chrome profiles, which the Swift package does
  not have.
- `SafariBinaryCookies`, `CookieDomainFilter`, `ImportedCookie` and the CSV
  password readers have no crypto and can follow in that PR, with the crypto,
  so `SQLiteSnapshot.swift` and `BrowserTime` go in that PR.
- The Keychain read (`KeychainSafeStorageNames`, `SafeStorageKeys`,
  `OneReadSafeStorage`) and `BrowserFolderGrants` stay in Swift in any case:
  this crate takes key material and decrypted secrets as inputs and never
  fetches a Keychain item.
