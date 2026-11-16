# Move a chat to an added machine

The chat header and the started chat's environment picker share the existing Move to… rows. Auto is first; This Mac and Cloud keep their existing actions; connected peers follow with placement's words (room for N, busy, or room unknown). A peer that cannot receive a move stays visible with its reason.

Use the shared menu's row height, font, gutters, hover and submenu keyboard behavior. Each target is one line, with its room after a middle dot. No new animation or container. References: the environment flyout in `manaflow-ai/cmux-design-references/apps/claude/live/NOTES.md` and this repository's `design/composer-menus.md`.

The daemon owns discovery and placement via `_acpmux/move_targets`; the webview only combines those rows with the existing native Cloud and This Mac paths. Read once per chat and when the menu opens, with replies bound to the same selected chat. No background polling.

Picking a machine calls the existing session move. A running turn asks once: Move after this turn or Move now. A dirty checkout is explained in the same question before carrying changes. A successful move opens the returned destination session; failure keeps the source chat open.

Gallery: `agent-pane.move-machine` has Auto with Cloud and SSH, a chat moving from SSH, and unknown/unavailable target states. The menu model tests verify ordering, preserved Cloud/This Mac actions, placement words, and refusal behavior.

Process failures retain exit status even when SSH emits no stderr. The move failure-detail regression detects empty-diagnostic errors; the transfer CLI test detects a move that loses history or queue order. A live probe on NIGHTLY 2a9cba423 observed an empty folder-preparation error once before a successful retry.
