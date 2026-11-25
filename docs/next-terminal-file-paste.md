# NEXT remote terminal file paste

NEXT's native clipboard and drop handlers hand image bytes or selected file
names to the Rust `cmux-tui __terminal-paste` client. The client connects to
the terminal's existing Unix endpoint or authenticated link bridge, resolves
the public terminal identity and takes a connection-owned view lease without
claiming geometry. It uploads through `paste-image` and commits only after
all bytes arrive. The daemon inserts its own shell-quoted path through the
PTY's paste primitive, including bracketed paste when enabled.

Images use `terminal-image-paste-v1`. Selected regular files additionally
require `terminal-file-paste-v1`: `begin` takes `filename` instead of `mime`.
Only a basename is accepted; the receiver chooses a private directory. Empty
files are valid. Directories, devices, FIFOs and unsafe basenames are rejected.
The transfer preserves existing chunk sizes, upload counts and expiry rules.
Committed files remain readable after the helper disconnects and expire after
ten minutes or when the terminal exits. A failed or uncertain commit is never
retried automatically. A missing capability or failed upload shows an error;
there is no fallback to inserting a client-local path.

The native session queues later typing behind the transfer. Ordinary text and
local terminal paste retain their existing behavior. Programmatic OSC 52 reads
cannot initiate uploads. Remote composer attachments already use the owning
machine's `file_put` path through `AgentPeerUploads`.

Regression coverage lives in the core `image_paste_tests`, the CLI
`terminal_paste` fixture, and native `TerminalRemoteFilePasteTests`. The CLI
fixture must read the path delivered to a real daemon terminal, open that file,
and compare its bytes with the source image; command acceptance alone is not
success. DEV acceptance additionally pastes a screenshot into a remote terminal
running an agent and reads the image back there.
