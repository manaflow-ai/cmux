# C4 `files`: file and media transfer between the phone and a Mac

Status: lane C4 of [PLAN.md](PLAN.md), 2026-10-06, branch `feat-cmux-next-ios-c4-files` off
`feat-cmux-next-ios`. Wire: [a0-rpc.md](a0-rpc.md) 3.4 and 5.6. Link: [a3-link.md](a3-link.md)
(bulk priority, budgets, resume). Host: [b5-mac-host.md](b5-mac-host.md) (`MobileChannelHandler`,
`MobileReadHandler`, gate, default deny). Shell seam: [a1-shell.md](a1-shell.md) 2.3 (`FileTransfer`).

## 1. Ownership

| Fact | Owner (single writer) | Others |
| --- | --- | --- |
| Bytes of a file on the Mac, its path, its digest | the Mac file system, written only by the C4 handlers in `MobileHost` | the phone sees listings and transfer results |
| Which directories a phone may touch | the Mac (`MobileFilePolicy` over `MobileFileRootsProvider`) | never the phone; the phone learns roots through `files.roots` |
| A partial upload (resume point) | the Mac upload staging, keyed by device install + sha256 + size | the phone learns the offset in `channel.opened` |
| A partial download | the phone's transfer journal + its local file | the Mac sees only `offset` |
| The transfer list, picker state, progress UI | the phone (client view state) | none |

A transfer is not shared state: nothing about it goes to the control plane, no DO mirror, no op
ledger. It is a stream between one device and one Mac (a0-rpc.md 1: bytes whose owner is the Mac are
`stream`).

## 2. Wire (A0 family `files`, additions in this lane)

Already in A0: `files.upload` and `files.download` channels (class `bulk`), `files.chunk` records
(`u64 LE offset` + bytes), `files.upload.end {sha256}` answered by `files.upload.done {upload, path,
size}`, `files.list` read. C4 adds, in `catalog.json`, the Swift and TS catalogs, schema and fixtures:

- `files.roots` read (stream plane, rpc channel): `{}` -> `{roots: [{id, name, path, writable}]}`.
  The phone browses only from these.
- Error `files.forbidden` on `files.upload`, `files.download`, `files.list` (outside every root,
  symlink escape, denied name). `files.too_large` also on `files.download`.
- Download end: the Mac sends the last chunk with the A0 `fin` flag (an empty chunk with `fin` when
  the file is empty or the resume offset is the size), then waits for the phone to close.
- Typed Swift params in `CmuxMobileWire/Files/` (`FilesUploadParams`, `FilesUploadOpenedParams`,
  `FilesDownloadParams`, `FilesDownloadOpenedParams`, `FilesListParams`, `FilesListResult`,
  `FilesRootsResult`, `FilesUploadEnd`, `FilesUploadDone`).

Cancellation is `channel.close` from either side (A0 3.3): the Mac keeps an upload partial for
resume; a phone that wants it gone simply never resumes and the partial expires.

## 3. Path scoping and authorization on the Mac

Default deny, enforced only on the Mac. `files.*` is served only to an admitted device (B5 hello
proof) and only while the session gate is open; each handler re-checks `gate.isOpen` before every
chunk, so a revoked device stops mid-file.

Roots. A request path is accepted only under a root from `MobileFileRootsProvider`:

- the inbox, default `~/Downloads/cmux-phone` (created 0700 on first write), writable;
- each workspace's directory as the app reports it (the workspace store's working directory per
  workspace; the app adapter supplies it), writable for uploads into `dest.path`, readable for
  download and list.

A root is refused when it is `/`, the home directory itself, an ancestor of home, outside home,
a dot-directory directly under home (`~/.config`, `~/.local`, ...), or inside or containing a
protected tree (`~/Library`, `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gcloud`, `~/.kube`,
`~/.docker`), compared without case. So a terminal whose cwd is `~` or `~/.config` exposes nothing.

Resolution (`MobileFilePolicy.resolve`):

1. The path is UTF-8, has no NUL, at most 4096 bytes. `~` and `~/` expand to the Mac user's home;
   anything else must be absolute.
2. Every root is canonicalized with `realpath(3)`. The target is canonicalized with `realpath(3)`
   when it exists, else its parent is canonicalized and the last component is appended (uploads).
   The canonical result must equal a canonical root or start with `root + "/"`. A symlink anywhere
   in the path that points outside every root therefore fails; a symlink that stays inside is fine.
3. No component of the canonical path below the root may be a denied name, compared without case:
   `.ssh`, `.gnupg`, `.aws`, `.azure`, `.kube`, `.docker`, `.netrc`, `.pgpass`, `.git-credentials`,
   `.npmrc`, `.pypirc`, `.password-store`, `.vault-token`, `Keychains`, `id_rsa`, `id_ecdsa`,
   `id_ed25519`, `id_dsa`. Hard links into a root are not detected (a phone cannot create one;
   residual risk noted).
4. Download opens the canonical path with `O_RDONLY | O_NOFOLLOW` and `fstat`s the descriptor: it
   must be a regular file (no FIFOs or devices), and its device and inode must match the resolved
   path's `lstat`, which closes the final-component swap race. A swap of an intermediate directory
   between steps 2 and 4 remains a residual risk (same user, same machine); the descriptor is what
   is read, never the path again.
5. Upload never overwrites: the final name is `name`, then `name (2).ext`, ... created with
   `O_CREAT | O_EXCL` in the canonical destination directory. The name is sanitized: path separators,
   NUL and control characters removed, leading dots stripped, at most 255 bytes, empty -> `file`.

`files.list` resolves like a download but requires a directory, never follows symlinks while listing
(`lstat`; symlinks report `kind: symlink`, size 0), omits denied names, sorts by name, pages by
`after` (exclusive) with `limit` (default 200, max 1000).

Caps (`MobileFilesConfiguration`, defaults): upload 1 GiB per file, download 1 GiB per file, chunk
128 KiB (below `hello.ok.max_frame` 256 KiB and the A0 1 MiB record cap), staged partials 2 GiB per
device counting bytes that live claims will still write (parallel opens cannot overcommit), a
partial of any device expires 24 h after its last write, free disk must stay above the reserved
bytes + 1 GiB (re-checked every 64 MiB received), 4 concurrent files channels per device (more are
refused retryable). Violations: `files.too_large` (`details.reason`: `file`, `quota`, `disk`).
Whole-file hashing and the cross-volume copy run on a dispatch queue, never on a cooperative thread.
After the last download chunk the handler closes its descriptor and gives the phone 30 s (injected
clock) to take the tail, then closes the channel.

Destinations. `dest.kind`:

- `terminal` and `composer`: the inbox. The Mac never types into a terminal on the phone's behalf;
  terminal input stays on the terminal channel (B5 3). The phone pastes the returned path itself.
- `path`: a directory under a writable root; a missing or non-directory path is `files.dest_invalid`,
  outside every root `files.forbidden`.

## 4. Resumable transfer

Upload (phone -> Mac):

1. The phone hashes the staged local file (sha256, streaming) and opens `files.upload {name, size,
   mime, sha256, dest}` on a `bulk` link channel (budget 4 MiB, `window` 4 MiB).
2. The Mac validates params, policy and caps, then finds or creates the partial at
   `~/Library/Caches/cmux/phone-uploads/<install-hash>/<sha256>-<size>.part` (outside TCC-protected
   folders until the final move). `channel.opened {upload: up_<16 hex of sha256(install|sha|size)>,
   offset: partial length}`; `resumed` is true when offset > 0.
   A new open of the same upload aborts a still-open older channel (a dead session the Mac has not
   noticed) and waits for it to release the partial, so a resume is never refused as busy. A reopen
   of an upload the Mac already placed answers `offset = size` and, on `files.upload.end`, the same
   `files.upload.done` path (a lost `done` never creates a duplicate).
3. The phone reads from `offset` and sends `files.chunk` records. The Mac accepts a chunk only at the
   exact current length (else `channel.closed {code: proto.bad_record}`), and never past `size`.
   `fsync` happens once, at the end; a crash loses at most the unsynced tail, and the next open
   reports the real length.
4. `files.upload.end {sha256}`: the Mac checks length == size, hashes the partial, compares with both
   the open's and the end's digest. Mismatch: delete the partial, `channel.closed {code:
   files.digest_mismatch}`; the phone restarts from 0 once, then fails. Match: re-check the session
   gate and re-resolve the destination against the current roots, move into it (exclusive create,
   then rename), `files.upload.done {upload, path, size}`, close.

Download (Mac -> phone):

1. `files.download {path, offset?}`. The Mac resolves, opens, hashes the file and answers
   `channel.opened {size, mime, sha256}`; then chunks from `offset` (clamped to size), last with `fin`.
2. The phone writes at the chunk offset into `<transfer>.part`, then verifies sha256 over the whole
   file, renames to the final local URL and closes. Mismatch deletes the part and fails
   `files.digest_mismatch`.
3. Resume: the journal keeps the digest from the first open. A resume sends `offset = part length`;
   if the reopened digest differs (the file changed), the part is discarded and the download restarts
   from 0.

Reconnect. Two layers, by design:

- Transport loss inside the link resume window (roam, Wi-Fi to cellular): `CmuxLink` replays retained
  reliable messages; the channel and the transfer continue untouched. Nothing in C4 runs.
- Session loss (link closed, app killed, resume window passed, Mac restarted): the phone's
  `FileTransfer.resume(id)` reopens with the journal, and the offset comes from the Mac (upload) or
  the part file (download). Only bytes after the offset cross the network again.

Back-pressure is the link's: a reliable `bulk` channel suspends `send` when 4 MiB are unacknowledged,
and acks are sent when the receiver consumes, so a slow disk or a slow phone throttles the sender with
no buffer growth on either side. `bulk` is the lowest priority, so terminal input and render frames
queued behind a transfer leave first (a3-link.md 4). On a relay path `bulk` fails with
`LinkError.unsupportedOnPath`, surfaced as "needs a direct connection".

## 5. Backgrounding

There is no background `URLSession` here: the bytes ride a `CmuxLink` session, which iOS suspends
with the app. Behavior:

- On `sceneDidEnterBackground` the transfer list asks for `UIApplication.beginBackgroundTask`
  (about 30 s) while any transfer runs, so short transfers finish.
- When the task expires, the expiry handler starts `pauseAll` and ends the background task before
  it returns (UIKit's rule); running transfers become `paused` in the journal and their channels
  close. A link lost in the background also leaves its transfer `paused` (retryable failure). The
  Mac keeps the upload partial (24 h).
- On foreground, every paused transfer resumes from the journal (`resume(id)`), from the Mac's
  offset or the local part length. A relaunch after the app was killed shows them paused with
  Resume. The journal uses `completeUntilFirstUserAuthentication` and is never written while an
  existing file cannot be read (a locked background launch), so it cannot be wiped.

A later option (not built): hand large uploads to the shipping web upload path through a background
`URLSession` into a Mac-pulled bucket. It needs a server-side store and is out of scope.

## 6. Phone side

Packages:

- One phone session per Mac: C1's `MobileLinkClient` (`Packages/Shared/CmuxMobileLink`; hello with
  the `MobileDeviceSigner` proof, odd channel ids, a new link session per generation). C4 added
  `helloOK()` and `read(_:params:)` (one shared `rpc` channel per generation, replies by id, an
  `error` reply throws `.refused`, cancellation settles the read). Terminals and files share it.
- `Packages/Shared/CmuxMobileFiles` (module `CmuxMobileFiles`, Foundation + CryptoKit, iOS and macOS):
  `MobileFileClient` over a `MobileLinkClient` (upload, download, list, roots, resume, digest;
  `MobileClientError` maps the client's errors), `TransferJournal` (JSON, protection until first
  unlock), `MobileTransferManager` (its connector returns the host's `MobileLinkClient`).
- `ios/CmuxiOS` `CmuxiOSFilesCore` (no UIKit): `LinkFileTransfer` (the real `FileTransfer`),
  `FileHostConnector` (host id -> the host's `MobileLinkClient`, filled by D1), `TransferListModel`
  (`@MainActor @Observable`), `ImageTranscoder` (HEIC -> JPEG), `StagedFile`, `ShellQuoting`.
- `ios/CmuxiOS` `CmuxiOSFiles` (UIKit): `FilePickerCoordinator` (PHPicker, camera via
  `UIImagePickerController`, `UIDocumentPickerViewController`), `TransferListViewController`,
  `FileSendActions` (send to terminal, attach to task, save to Mac inbox), `QuickLookFileViewer`.

Pickers. PHPicker needs no photo library permission (out of process); items load as file
representations and are copied into `tmp/cmux-transfers/<id>/`. Camera needs
`NSCameraUsageDescription` (already in the app) and checks `AVCaptureDevice.authorizationStatus`.
Document picker imports copies (`asCopy: true`). HEIC -> JPEG is a user setting (default on, matching
what most Mac tools read): ImageIO re-encodes at quality 0.85 keeping orientation; other formats pass
through unchanged. The shipping app's 2048 px downsample applies only to "attach to task" images
(agent context), never to "save to Mac".

Entry points, all through seams in `CmuxiOSFeatureKit/Files`:

- Send to terminal: upload with `dest.kind = terminal`, then `TerminalPathPaster.paste(path:terminal:)`
  inserts the POSIX single-quoted path plus a space (parity: `TerminalComposerAttachmentInsertion`).
  C1/D1 implement the paster with a `terminal.input` `paste` record.
- Attach to task (C8 seam): `FileAttachmentSink.attach(_ attachment: FileAttachment)`, where
  `FileAttachment` = transfer id, host id, remote path, name, mime, size. C8 keeps
  `TaskDraft.attachments: [TransferID]` and resolves paths from the attachment it was handed; the
  composer can also start the pick itself through `FileSendActions.pick(for: .composer)`.
- Viewer hook (C13): `FileViewerHook.present(_ file: LocalFile, from:)` where `LocalFile` = local URL,
  name, mime, remote path. Downloads finish by calling it; the default is QuickLook. C13 replaces it
  with its text/Markdown/image/PDF viewer and can call `FileTransfer.start` with `.download` itself.

Progress is `TransferProgress` (completed, total, state; `remotePath` on a finished upload). The
transfer list shows name, host, direction, bytes, speed (computed in the view from successive
reports), and Cancel / Resume / Retry; cancel closes the channel at once.

## 7. Tests

`Packages/Shared/CmuxMobileHost/Tests` (policy, handlers over the B5 loopback `PhoneHarness`) and
`Packages/Shared/CmuxMobileFiles/Tests` (client against a real `MobileHost` with the C4 handlers on
`CmuxLinkTesting` loopback and lossy networks): upload and download round trips with sha256;
transport drop mid-file continues on the same channel; session loss mid-file resumes from the Mac's
offset and sends only the rest; download resume from a part file and restart when the file changed;
digest mismatch refusal; `..`, absolute escape, symlink escape, denied names, home-as-root refusal;
cancellation closes the channel and keeps the partial; back-pressure bounds the sender while the
receiver stalls; revocation stops a transfer mid-file; list paging and symlink reporting.

## 8. SFTP (C9 hosts; scoped, not built)

SSH hosts (C9) have no `MobileHost`. Files there go through SFTP on the C9 connection owner
(`SSHConnection` opens an `sftp` subsystem channel; SwiftNIO SSH has no SFTP client, so a small
SFTP v3 client is needed: `open`, `read`, `write`, `fstat`, `readdir`, `realpath`). It plugs in as a
second `FileHostConnector` kind behind the same `FileTransfer`: resume by `fstat` size of the remote
partial, digest by local hash plus `sha256sum` over an exec channel when available. Scoping is the
server's (the user's own account); the phone adds no policy. Estimated one lane-sized change after
C9 lands its connection owner.

## 9. Not in this lane

The carrier that dials a real Mac from the app (B2/B4 + D1 fill `FileHostConnector`), B6's
Secure-Enclave signer behind `MobileDeviceSigner`, the app's `MobileFileRootsProvider` over the
workspace store (cmux-next app wiring, no local Mac build here), C8's composer UI, C13's viewers.
