# CMUX Vault cloud sync MVP design

## Scope

Round 1 adds a standalone Go CLI, `cmux-vault`, plus authenticated web API
routes under `web/`. The CLI discovers Claude Code, Codex, and pi JSONL
transcripts on disk, zstd-compresses changed files, uploads bytes directly to
S3-compatible storage with presigned URLs, commits metadata to Postgres, and can
restore a missing transcript for agent resume.

## Upload cadence

MVP cadence is manual: users run `cmux-vault sync` when they want a catch-up.
The sync path is incremental by size and mtime first, then sha256 for changed
files, so frequent manual runs are cheap.

Next recommendation: add a launchd job or cmux-managed daemon that watches file
close events for supported transcript directories, debounces for a few seconds,
and runs an hourly catch-up scan. The hourly scan is still needed because agent
write patterns and filesystem notifications are not perfectly reliable.

## Metered and cellular awareness

The CLI does not enforce network policy in round 1. The intended config shape is
a future `wifi_only` boolean with these semantics: when true, background sync
skips expensive or constrained networks, while explicit manual `sync` still runs
after warning the user.

Recommended implementation: use `NWPathMonitor` in the cmux mac app, or a tiny
Darwin sidecar, to surface `isExpensive` and `isConstrained` to the sync daemon.
The pure Go CLI should remain portable and accept the policy decision from that
host integration rather than guessing from interface names.

## Security and privacy

Transcripts can contain secrets, prompts, source excerpts, command output, and
credentials accidentally pasted into terminals. Treat them as sensitive private
data.

Storage isolation is by tenant prefix: object keys are derived only on the
server as `vault/u/<userId>/<agent>/<agentSessionId>/<sha256>.jsonl.zst`.
Clients never supply object keys. API queries always filter on the authenticated
Stack `user.id`, and presigned URLs are only minted for keys owned by that user.
The web server never proxies transcript bytes; clients upload and download
directly over TLS using short-lived presigned URLs.

Follow-ups: client-side encryption before upload, optional local redaction rules
for common secret formats, and explicit delete/GC API routes so users can remove
cloud copies without waiting for retention policy.

## Retention and storage growth

Snapshots are content-addressed by sha256 under each session. Re-uploading the
same content is deduped by the server metadata and object key. A session points
at the latest snapshot, while older snapshots remain available for audit or
future timeline restore.

Recommended GC policy follow-up: keep the latest snapshot for every session,
keep all snapshots younger than 30 days, and remove older superseded snapshots
unless the user pins them. A delete API should remove metadata first, then queue
object deletion so storage and Postgres converge even if object deletion fails
temporarily.

## Quotas and limits

Round 1 enforces request shape limits, a max batch size of 25 items,
`CMUX_VAULT_MAX_UPLOAD_BYTES` on compressed upload size (default 512 MiB), and
`CMUX_VAULT_MAX_USER_BYTES` on total stored compressed bytes per user (default
50 GiB). The uploads route checks the projected total before presigning and the
commit route re-checks it, so previously issued URLs cannot bypass the cap.
Quota and size failures are per-item (`upload_too_large`, `quota_exceeded`) so
one oversized transcript does not block the rest of a batch.

`/api/vault/cli/auth/start` is throttled per IP through the Vercel firewall
rule shared with the feedback/waitlist endpoints, garbage-collects expired rows
on every call, and caps globally pending (not yet approved) requests at 500 as
a distributed-flood backstop; completed logins never consume capacity.

Remaining quota follow-up: per-day uploaded bytes, max sessions, and max
snapshots per session.

## OpenCode and Gemini adapters

OpenCode moved to SQLite at `~/.local/share/opencode/opencode.db`, so it should
not be treated like a JSONL file tree. Add an adapter that opens the database
read-only, exports each session to a stable JSONL or JSON snapshot stream, and
uses the database row id as the agent session id.

Gemini should slot in through the same `Agent` interface once its current local
session format is verified. The adapter must provide discovery, stable relative
identifiers, restore path behavior, and a resume hint without changing syncer or
resume logic.

## Monorepo rationale and extraction path

Keeping `vault/` and `web/` in the cmux monorepo lets the CLI, API routes,
schema, migrations, and docs evolve atomically while the cloud contract is still
small. This also keeps Stack Auth and database conventions consistent with the
native app backend.

If `cmux-vault` becomes useful outside cmux, extraction is straightforward:
freeze the HTTP API, move `vault/` to a new repository, keep the Go module path
or add a compatibility module, and publish release binaries from the extracted
repo while the `web/` API remains in cmux.
