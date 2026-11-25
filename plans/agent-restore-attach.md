# Agent restore attach usage

This fix covers three restart paths:

- Quit to update: cmux closes, the agent continues under its original owner, and relaunch must bring back a view attached to that session.
- Crash: the app can disappear while the agent keeps running, so the next launch must attach the saved tab instead of starting a second writer.
- Session moved elsewhere: a live owner may be on another host or launcher. When cmux cannot safely render an attach command, restore keeps a placeholder tab with the owner location and an Attach action or command.

The attach view is for an existing owner. A live owner must never be resumed a second time. Claude sessions use the original launcher when it is recorded, then `claude attach <session-id>`; tmux sessions use `tmux attach` with the saved target. If no safe attach command can be derived, the restored placeholder remains visible so the user can attach manually.
