# Clipboard images in Cloud terminals

Cmd+V in a managed Cloud terminal uploads the prepared image to that terminal's
cmux-tui daemon and pastes its remote filename. Codex and Claude receive the path
through the daemon's bracketed-paste operation and can read the image on the VM.
The clipboard's Mac filename is never submitted to the Cloud process.

The Mac reuses `TerminalImageTransferPreparationService`, including its isolated
clipboard materialization worker. `CloudTuiManualMirrorSession` supplies the existing
authenticated `CloudMachineLink` mux connection and attachment lease. No public
upload endpoint, shell receiver, provider exec request, or second credential is used.
Terminal-initiated clipboard queries (OSC 52) cannot initiate an image upload.

## Compatibility and scope

Both native paste routes (a ready Ghostty surface and a paste queued before surface
readiness) use the same Cloud coordinator. Local terminals, detected SSH, remote
tmux, Ctrl+V key delivery, drag/drop, and the iOS paste RPC retain their existing
routes. Copied text remains text. The optional command buffer refuses Cloud image
attachments with an instruction to paste directly into the terminal; it must not
send an attachment before the user submits the buffer.

The daemon must advertise **`terminal-image-paste-v1`** in `identify`, alongside
leased attachments. This is an additive capability on mux protocol 12. Protocol
12 alone is insufficient: older protocol-12 daemons do not implement it. The Mac
shows an update/reconnect error for an older daemon and never falls back to a Mac
path. Linux, Android, and Apple daemons advertise it; other platforms do not.
Update the machine's cmux-tui daemon before enabling this client behavior in a
rollout. Reconnect after updating so capabilities belong to the new connection.

## Limits and ownership

- PNG, JPEG, GIF, and WebP only, checked by content signatures on both sides.
  Each image is limited to 20 MiB. Filesystem reads run off the Mac's main actor;
  cancellation is checked before and after the bounded regular-file read.
- One acknowledged 48 KiB chunk at a time, with a 120-second transfer deadline.
  The existing activity indicator and Cancel button show transfer progress. A
  single outstanding chunk trades throughput on high-latency links for bounded
  memory and explicit ordering. Uploads use the transport's bulk lane; commit shares the ordered keyboard lane.
- At most eight images per connection, 32 retained uploads, and 128 MiB reserved
  on a daemon. Pending uploads reserve their entire declared size before bytes
  arrive. Recovered files count against the same storage limits. Failed deletion
  keeps the reservation charged and the upload retired until a safe retry succeeds.
- The daemon chooses a random, private `cmux-image-…` directory below its temporary
  directory inside a verified private per-UID namespace, mode 0700, and a
  `clipboard.<extension>` file, mode 0600. Unsafe writable ancestors are refused. The terminal
  process normally has the same Unix owner as its daemon. The protocol accepts
  no destination path and returns no path in transfer acknowledgements.
- Every request requires the same connection-owned lease, public terminal ID,
  surface, and authoritative workspace ownership. Reconnect, replacement, and
  workspace changes invalidate an in-flight transfer instead of retargeting it.
  A terminal may have several valid leased views; the resolver’s representative
  view is not treated as a separate authorization requirement.
- Uncommitted uploads expire after two minutes or on disconnect/cancellation.
  Committed images survive link reconnect for ten minutes so an agent can finish
  reading them, and are removed on terminal exit or daemon shutdown. Cleanup uses
  the public terminal identity, so closing a view preserves the attachment while
  closing the terminal or keeping its final screen after exit removes it.
- A private, synced ownership receipt permits cleanup after a daemon crash. On
  restart, the reaper checks the recorded directory/file inodes **and a random
  persistent ownership marker on the file**; inode reuse cannot claim a replacement.
  The temporary filesystem must support extended attributes; uploads fail closed
  when that ownership proof cannot be stored. Expiry is twelve minutes from upload
  creation (two to transfer, ten to read), reconciled by recurring recovery sweeps.
  Sweeps continue across 64-entry batches and repeat every 30 seconds after a full
  pass. Transient cleanup failures retain the receipt and can be retried.
  A stopped VM cannot run cleanup; the deadline is reconciled when its daemon
  restarts. Recovery does not claim arbitrary paths or follow symlinks.
- Cleanup removes only owned entries. Replacement files, replacement symlinks,
  and unrelated user files survive; directories are never recursively removed.
  When ownership cannot be proven, preserving the file takes precedence over
  deleting it. Empty files left before receipt creation contain no clipboard bytes.

Cancellation before commit cannot paste a path. Once commit starts, a lost
acknowledgement means delivery is uncertain. cmux asks the user to inspect the
agent before retrying; it does not retry automatically or delete a potentially
delivered attachment. Multi-image clipboard selections are separate transactions,
so an earlier image may already be attached if a later image fails.

The OS security boundary is the VM Unix account. Separate agents running as that
account can access its files; the protocol’s session/lease checks are not a separate
per-agent filesystem sandbox. This matches existing authenticated Cloud file operations.

No image contents or source paths are included in transfer diagnostics. Errors are
stable codes, localized on the Mac in all nine supported locales. The existing
managed file-transfer restriction also applies.

## Verification

The tests cover routing, ordered chunks and paste, capability rejection, cancellation,
disconnects, uncertain delivery, content/size rejection, identity fencing, quotas,
expiry, crash recovery, and preservation of user files and symlinks. The daemon
behavior test records the actual `Surface.write_paste` bytes and opens the resulting
file; it requires both bracketed-paste delimiters.

Run cmux-tui checks on hosted machines, never by compiling on the local Mac:

```sh
./scripts/verify-cmux-tui-hosted.sh --filter cloud_image_paste
```

Mac coverage: `CloudImagePasteRoutingTests`, `CloudImagePasteCoordinatorTests`, the
existing `TerminalAndGhosttyTests`, and the existing image preparation/concurrency
tests. Use hosted CI and an approved tagged cloud build for live verification.
Live acceptance requires copying an image on the Mac and pressing Cmd+V in both
Codex and Claude inside a managed Cloud terminal; a standalone local daemon test
does not establish that the full authenticated Cloud path works.

Related: [#12476](https://github.com/manaflow-ai/cmux/issues/12476),
[#1660](https://github.com/manaflow-ai/cmux/issues/1660),
[#6039](https://github.com/manaflow-ai/cmux/issues/6039),
[#823](https://github.com/manaflow-ai/cmux/issues/823),
[#1664](https://github.com/manaflow-ai/cmux/issues/1664),
[#7046](https://github.com/manaflow-ai/cmux/pull/7046),
[#5602](https://github.com/manaflow-ai/cmux/pull/5602).
