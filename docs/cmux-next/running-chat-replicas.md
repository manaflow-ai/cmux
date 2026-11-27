# Recover an ordinary Cloud chat from a running replica

Ordinary Cloud chats can checkpoint their journal and supported agent-native state while a
turn is running, including a silent tool call. This is a separate opt-in from cold history
offloading. Auto chats keep their existing fenced checkpoint path.

In the daemon's existing `session-cloud.json`, add `"runningReplica": true`. Keep the
existing `store`, `credentialFile`, `keyFile`, and `rootPrefix` configuration. The default
is off. The Cloud activity worker captures ordinary running or permission-waiting chats
serially, with a 30-second delay after each pass. A slow upload can extend that interval.
It uses the existing store's authorization; unsupported machine credentials still fail.

Inspect the opt-in and the latest 4,096 chat checkpoint receipts, or capture an enrolled chat now:

```sh
acpmux running-replica status --json
acpmux running-replica checkpoint CHAT --json
```

Keep the receipt's `pair`, the original chat UUID, the original `rootPrefix`, and the
history encryption key outside the source machine. The server cannot reconstruct a lost
key. The sync store has no root-list endpoint; a receipt is the direct recovery address.
If only the receipt was lost, an authorized recovery machine with the original key and
root prefix can derive the same address:

```sh
acpmux running-replica address ORIGINAL_CHAT_UUID --json
```

Restore the working directory separately from the machine snapshot. Configure the
recovery daemon with authorized store credentials and the original history key. Recovery
does not require enabling automatic replicas on the destination:

```sh
acpmux running-replica recover PAIR --cwd /absolute/restored/project --name recovered-chat --json
```

Native capture currently supports Claude, Codex, and Pi. The command creates an idle chat
with a new identity. It refuses native-session collisions
and unsupported native recovery formats. Interrupted tools have an unknown outcome; check
their external effects before asking the recovered agent to continue. Queued prompts and
scheduled work remain inert history, so importing or restarting the daemon cannot replay
them. This is a recovery copy, not a takeover of a source that may still be alive.

Each receipt is published only after its encrypted manifest and chunks are uploaded. A
failed publication leaves the last good root intact. Unchanged chunks reuse their previous
encrypted blobs. Authentication, digest checks, path validation, and the existing sync
store's retention apply; currently an unrefreshed root expires after 90 days. Working-tree
files, external processes, tool effects, and events after the captured journal high-water
mark are not part of this replica. The receipt reports the captured file and byte counts,
not a count of lost workspace files.

The regression detector is `running_replica`: storage tests recover more than 1,000
journal records after deleting the source and reject tampering and unsafe paths; hub tests
exercise interrupted-turn recovery and inert queued work.
