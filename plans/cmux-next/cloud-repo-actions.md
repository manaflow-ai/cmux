# Cloud chat repositories

The daemon owns the repository contract used by `cmux cloud repo`, `cmux mcp`, the app and
acpmux's Cloud-only `list_repos` / `add_repo` tools. Requests use the existing daemon JSON-line
protocol: `{id,cmd,...args}`. Replies use `{id,ok:true,data:RESULT}`. Typed repository failures
are RESULT objects, so recoverable failures retain their action data. Transport authorization
failures retain the normal `ok:false` envelope.

| Action | Arguments | Result |
| --- | --- | --- |
| `cloud.repo.list` | `{session,query?}` | `{repos:[{fullName,private,source}],connect?:{install_url}}` |
| `cloud.repo.add` | `{session,repo,ref?}` | `{state:"done",repo,folder,head}` or typed failure |
| `cloud.repo.attached` | `{session}` | `{repos:[{state:"done",repo,folder,head,notes?}],pending:[{repo,state:"running",phase?,progress?,notes?}]}` |
| `cloud.repo.wait_github` | `{session,timeout_ms?}` | `{connected:boolean}` |
| `cloud.repo.local` | `{}` | `{repos:[...],recent:[...],complete:boolean}` |
| `cloud.repo.sync` | `{repos,recent?,complete?,install_url?}` | `{synced:number}` |
| `cloud.repo.remember` | `{session,attachment:{state:"done",repo,folder,head}}` | `{remembered:true}` |

`session` is the chat ID, a single safe path component. It is not the daemon session selector.
A bare repo name is resolved in source order: local Mac remotes, previous Cloud chat repos,
then all pages of the GitHub installation catalog. One match attaches; multiple matches within
one source return `repo.ambiguous` with `choices` in the same repo-row shape. An explicit
GitHub URL or owner/name can clone publicly without asking for credentials first.

## Mac-to-machine route

The existing authenticated machine link is dialed by the Mac. The Mac asks its own daemon for
`cloud.repo.local`: Rust reads the project registry (including recent/imported folders) and
bounded GitHub remote URLs. Only names and conservative visibility flags leave the Mac, never
folder paths or Git credentials. Before chat startup and repository actions the app forwards
that export through `cloud.repo.sync` on the machine. An incomplete scan must not replace the
last complete catalog. Successful machine attachment records are forwarded to the Mac through
`cloud.repo.remember`; subsequent exports include them as `recent`, allowing new machines to
rank the same history. Both local and remember are denied over remote links.

The Mac obtains `install_url` using its user-authorized connector install endpoint and forwards
it with the catalog. Machine VM bearers can enumerate repositories, but cannot execute
`integration.connect`; this feature does not widen that permission. The machine's root Cloud
agent accepts `{github_repos:{query?,cursor?}}`, fixes team/environment from its binding, and
uses `GET /v1/connectors/github/repos`. A proven unlinked account returns `connect:{}` when
VM install-link issuance is refused; the daemon fills the URL from the synchronized catalog.

## Clone, recovery and persistence

The only clone implementation is git-seed-v1: `git.seed.start` with `{folder,url,repo,ref?}`,
then `git.seed.status {job}`. The destination is `~/chats/<session>/<repo-name>`. Saved job IDs
resume an interrupted wait, and successful attachments are durable daemon projections keyed
by chat. Repeating an already attached repo returns its record. Different repositories that
need the same destination cannot reuse each other's clone job.

Failures contain `{code,message,install_url?,org?,choices?}`. Codes are `repo.needs_github`,
`repo.no_access`, `repo.not_found`, `repo.ambiguous`, `repo.not_github`, and seed failures.
Every message names a next action. `repo.not_github` directs the user to the project-copy flow.
`repo.needs_github` also contains:

```json
{"retry":{"action":"cloud.repo.add","args":{"session":"chat-id","repo":"name"},"wait_action":"cloud.repo.wait_github"}}
```

The UI card opens the supplied URL, waits for the connector to become available, and replays
exactly those args without a user message. Agent tool results describe that automatic retry.
The wait is bounded (30 seconds by default, at most 60); the card may re-arm it while mounted.
Clone status waits stop after nine minutes and return an actionable resume response. Each
request owns its socket and worker; no perpetual observer or timer is installed.

An unlinked connector's typed `repo.needs_github` error is equivalent to `connect`:
list exposes its install link, wait reports disconnected, and add supplies the retry payload.
Seed start refusals keep their typed error even without a job. `seed.checkout_failed` asks for
an existing branch, tag or full commit SHA; `seed.unknown_job` clears the saved job so retry
can start again; `seed.unavailable` directs the user to a Cloud machine. Clone-only mode does
not accept sparse checkout arguments.

Running jobs expose `phase` and `progress:{received_bytes,objects,total_objects}` through the
`pending` array. Updates emit the existing `FrontendProjectionChanged` event for frontend
`cloud-repos`, scope `session`, subject `catalog`, at most once per second while polling;
completion always emits its final state. The UI refreshes attached repositories on this event.
Successful attachments also retain optional `notes:["lfs_unavailable"|"lfs_failed"]`.

The feature requires the machine daemon's git-seed-v1 clone-only implementation and a platform
deployment with the GitHub connector enabled. The matching app changes provide startup sync,
Session Info rendering and automatic card replay. Tests use fake connector and seed sockets.
