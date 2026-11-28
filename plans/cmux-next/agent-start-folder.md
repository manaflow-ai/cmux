# Agent chat start folder (cx-nn3e, 2026-10-09)

Builds on AGENT-CWD-FOR-FOLDERLESS-WORKSPACE (spec decisions.md, 2026-10-05 and amendments) and
on "Remove dialogues." (Lawrence 2026-10-07, #18347).

## Problem

Lawrence's screenshot of a new chat in a fresh workspace: the folder chip said `~`, the line above
the composer said "New chats in this workspace start in a private folder", the start failed with
"Couldn't start Claude Code: This folder is outside the folders this pane may use. [Retry]", and an
"Add this folder to the workspace?" sheet floated at the pane's top-left, all at once.

Cause: the fresh workspace's New Tab page sits at `~`. The host already dropped that `~` from the
handshake (so the page offered Choose Folder…), but the page's agent row started the chat with the
page's raw `cwd` (`~`). The harness switch drew `~` on the chip, the relay refused it, and the old
sheet offered to add it. After #18347 the same click silently made `~` a root instead, so the chat
started in the whole home folder.

## Decisions

1. One start folder. The host names a new chat's folder in the handshake (`cwd`): the seed or New
   Tab folder unless it is `~`, `/` or agent-home, else the workspace's first folder (the relay's
   fill, `primaryRoot`). No folder: `chooseFolder` and the chat starts in agent-home. The page keeps
   that value as the chat's start folder; the chip shows it, and every start of the new chat (the
   New Tab agent row, a harness pick, the first Send, New Tab variant A) sends it. A page's
   inherited folder is a terminal's folder only.
2. A folder the user picks goes through the host first (`workspace.useFolder {cwd, confirm}`):
   `ok` (used at once; a folder outside every root still passes on the user's click, as #18347
   decided), `confirm` with reason `home` for the home folder, `refused` with reason `root` for `/`
   and every folder above the home folder.
3. The home folder is asked about once, inline above the composer (in the place of the
   private-folder line), before any chat starts there: "Start this chat in your home folder? The
   agent can read everything in it, and macOS may ask for access to Photos, Documents and other
   folders." Buttons: Use Home Folder (the answer spends its click's gesture, makes `~` a root and
   makes it the chat's folder; no Retry follows) and Use Private Folder (or Keep <folder> when the
   chat has a workspace folder), which leaves the chat unstarted where it was. No window sheet.
   Send waits while the question is open.
4. The relay's typed-folder rule (#18347) never covers `~` or above: a plain click on a start in
   `~` stays refused; only decision 3's answer makes `~` a root.
5. The New Tab page's open folders (gesture roots) and grants never hold `~` or above either,
   except the home folder itself granted by decision 3's answer.
6. Known limit: decision 3's answer, like every pane gesture, is a recent real click or key in the
   pane (about 30 s). A page script that runs while the user types could send the answer without
   the question showing. Only a native confirmation would close that, which "Remove dialogues."
   rules out; the relay still never starts `~` without that answer.
7. A started chat's location move (shell/chatMoves.ts) is not gated: it changes only where the
   pane's own shell commands run and adds a note to the next prompt.

The machine chip's "(2)" is macOS's own computer name (`SCDynamicStoreCopyComputerName`, the
Sharing name macOS suffixes after a name conflict); cmux adds nothing.
