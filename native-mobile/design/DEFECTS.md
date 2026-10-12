# cmux-next native iOS: QA defect log

Found by the looped QA pass (simulators `cmux-native-qa`, `cmux-native-qa2` on
the build Mac, headless host `nxdemo`). Severity: S1 blocks a core flow, S2
wrong behavior with a workaround, S3 polish. Status: fixed (commit), open,
owner-handoff (written up for the owning agent).

| # | Area | Defect (repro, expected vs actual) | Sev | Status |
| --- | --- | --- | --- | --- |
| 1 | Connectivity | Restart the host bridge while the app is open: the link reconnects and terminals reattach, but the `svc` channel is never reopened, so Files, Changes, attachments and Feed replies fail until the app is relaunched. Cause: `HostConnection.openControl` only opened `svc` when `services == nil`. | S1 | fixed: reopen `svc` when the old channel ended; `ServiceClient.isClosed` |
| 2 | Errors | Link failures surfaced as "The operation couldn't be completed. (CmuxNativeLink.LinkError error 1.)". | S2 | fixed: `LinkError` is `LocalizedError` with plain copy |
| 3 | Connectivity | Every `.connected(path)` change (direct to relay, ICE restart) re-ran `openControl`: a second control channel, re-subscribe and terminal reattach, while the old control channel leaked. | S2 | fixed: keep live channels on a path change; close the old control before replacing it |
| 4 | Terminal resize | Each layout pass during a keyboard animation sent `resize-surface` from its own unstructured Task, so requests could reach the daemon out of order and leave the Mac on a stale intermediate grid (observed 16, 17, 19 and 20 rows for the same keyboard state in vim). | S2 | fixed: one in-flight resize, latest size wins (`TerminalSession.resize`) |
| 5 | Terminal / TUI | Open a terminal while vim (any alternate-screen TUI) runs, then quit vim: the shell screen comes back empty except the new prompt; earlier output and the command line are gone on the phone while the Mac still has them. Cause: the daemon's `vt-state` replay taken in the alternate screen carries no primary screen. | S2 | fixed: on the first alternate-screen exit after such a replay, attach again for a fresh replay |
| 6 | Attachments | Uploaded paths were only quoted when they contained a space; `Aziz's notes.pdf`, `a$b.txt`, `x&y.png` broke the typed shell command. | S2 | fixed: `ComposerModel.shellQuoted` (POSIX single quotes), tests |
| 7 | Attachments | Upload progress only moved between attachments (a 40 MB video sat at 0% until done) and there was no way to cancel; an upload with no returned path typed an empty string. | S2 | fixed: byte progress across attachments, cancel button (X) while sending, missing path is an error |
| 8 | Feed | "Mark all read" only marked posts read on the phone; the next backfill brought them back unread. | S3 | fixed: acknowledges each unread terminal on the Mac |
| 9 | Memory | `AppModel.connect` captured the new `HostConnection` strongly inside closures the connection owns, so every host switch or manual reconnect leaked the old connection with all its terminal sessions and Ghostty surfaces. | S2 | fixed: weak captures |
| 10 | Files | Leaving a file preview mid-download kept pulling the whole file (up to 64 MB) in 512 KiB chunks and then wrote it to a temp folder nobody cleaned. | S3 | fixed: `ServiceClient.read` stops between chunks when its task is cancelled |
| 11 | Composer | Sending while the terminal was attaching or reattaching (after a reconnect) cleared the composer, but `TerminalSession.enqueueInput` drops input without a client: the message vanished. | S2 | fixed: the composer keeps the draft and says so unless the session is live |
| 12 | Files | A text file with an unknown extension and multi-byte UTF-8 (CJK) could preview as binary: the 8 KiB sniff dropped exactly 3 bytes at the cut, which can split the previous character. | S3 | fixed: try dropping 0 to 3 bytes; tests |
| 13 | Feed | A "finished" or notice post whose reply contained a numbered list ("1. Install 2. Test") showed the items as answer buttons; tapping one typed the digit into the agent's idle prompt. | S2 | fixed: only question and permission posts take numbered choices (`FeedItem.takesOptions`) |
| 14 | Attachments | Attachment names used a locale-dependent `DateFormatter`: Thai shows year 2569, Arabic shows Arabic-Indic digits in the file name typed into the shell. | S3 | fixed: en_US_POSIX, Gregorian |
| 15 | Attachments | Any file size was read whole into memory and sent base64 (a 1 GB video would exhaust memory). | S2 | fixed: 200 MB cap checked before reading files and on add, with a clear message |
| 16 | Attachments | Photos from the library were uploaded as HEIC; Claude Code and Codex can't read HEIC, so "look at this screenshot/photo" failed on the agent side. | S2 | fixed: HEIC/HEIF/TIFF become JPEG (0.9) before upload |
| 17 | Connectivity | A Files, Changes or preview screen open across a reconnect kept the dead `ServiceClient`; Retry failed until the screen was closed and reopened. | S3 | fixed: one `ServiceClient` per connection, `rebind` to the new `svc` channel (old in-flight calls fail, old reader can't close the new binding) |
