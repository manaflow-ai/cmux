# Rewind a Cloud machine to a turn

Whole-machine rewind restores a captured turn's files, running processes, memory, and database state. It uses the workspace's new Cloud machine and requires its owner to be signed in to the cmux app.

List captures for the workspace open in the app:

```sh
cmux --json machine turns --workspace ws_example
```

Choose a ready capture's session and turn, then rewind:

```sh
cmux --json machine rewind --workspace ws_example --session session_example --turn turn_example --key rewind_example
```

The command reads the current machine generation and submits it with the selected capture. A running turn or a concurrent machine change refuses the rewind. On success it returns the new generation and rewind receipt after reconnecting the workspace to the replacement machine. The workspace's logical machine ID stays the same.

The app remembers owner-verified workspace bindings for the signed-in account. Refresh and relaunch resolve the workspace's current connection through the owner API before connecting, so a retired source machine cannot replace or remove the restored workspace. An unavailable owner API preserves the last list and refuses an unverified reconnect.

If the connection fails after submission, retry with the same `--key` and original `--generation` printed before submission (also returned as `expectedGeneration` in the JSON result or error). Use the complete retry command printed on stderr. The platform returns the existing result for that key; it does not allocate another replacement machine. Use a new key for a later intentional rewind. An owner token never appears in this command's arguments or output.

The edited-files card's Undo action remains a file revert. Whole-machine rewind is a separate operation.
