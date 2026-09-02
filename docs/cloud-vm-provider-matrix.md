# Cloud VM provider and transport matrix

This is the compatibility reference for Cloud VM sessions. It describes the
provider and image generations that cmux can create today. A provider name is
not enough to select a session transport: an existing machine's image and
platform marker are authoritative.

## Matrix

| Provider and machine generation | Session transport | Snapshot / restore | Fork | What `cmux vm` can use |
| --- | --- | --- | --- | --- |
| Blaxel, current cmux-tui image | `cmux-remote` | No cmux checkpoint API. Blaxel standby may resume an automatic state snapshot, but it is not a `cmux vm snapshot` resource. | No | `vm tree`, `vm open`, `vm terminal send|read|wait`, `vm exec`, ports, and the other cmux-tui session operations |
| E2B, current cmux-tui image | `cmux-remote` | Yes | No | cmux-tui session operations, plus `vm snapshot` and `vm restore` |
| Daytona, current cmux-tui image | `cmux-remote` | Yes | No | cmux-tui session operations, plus `vm snapshot` and `vm restore` |
| Freestyle, legacy platform or `cmuxd-ws` snapshot | `websocket`; `ssh` may be available as a shell fallback | Yes | Yes | Legacy PTY/RPC attach, `vm exec`, and `vm ssh`; no cmux-tui workspace or terminal tree |
| Freestyle, beta cmux-tui devbox image | `cmux-remote` | Yes | No | cmux-tui session operations, plus `vm snapshot` and `vm restore` |

`cmux-remote` is the session transport for the cmux-tui daemon. It carries
workspace and terminal state, so the Cloud tree and headless terminal verbs
have one source of truth. `websocket` is the legacy `cmuxd-remote` PTY/RPC
transport. It can provide a terminal stream, but it cannot provide the
cmux-tui workspace tree. `ssh` is a management or shell transport, not a
substitute for a cmux-tui session.

Provider documentation explains related lifecycle behavior: [Blaxel standby
snapshots and volumes](https://docs.blaxel.ai/Sandboxes/Overview), [Blaxel
persistent volumes](https://docs.blaxel.ai/api-reference/volumes/create-persistent-volume),
[Freestyle VM CLI snapshots](https://www.freestyle.sh/docs/vms/cli), and
[Freestyle SSH access](https://www.freestyle.sh/docs/vms/ssh). These provider
features do not change the cmux transport selected for an existing machine.

## Capability and error guidance

1. Run `cmux vm ls --json` and inspect each machine's `provider`, `image`, and
   `capabilities`. Treat `capabilities.snapshot`, `capabilities.restore`, and
   `capabilities.fork` as the server's answer for checkpoint operations. The
   `capabilities` object is provider-derived and can be broader than one
   provider's legacy and current image generations, so an operation can still
   be rejected for a specific machine.
2. Use the attach transport requested by the machine generation. Current
   cmux-tui machines require `cmux-remote`; legacy Freestyle machines require
   `websocket` or `ssh`. Do not retry a rejected transport against the same
   machine.
3. `vm_attach_transport_unsupported` means the requested transport is not
   served by that machine. Follow the error's `supported` list. A legacy
   Freestyle machine cannot be upgraded in place to cmux-tui by changing a
   client flag; recreate it from a cmux-tui devbox image.
4. `vm_operation_unsupported` (or an HTTP 501 for snapshot, restore, or fork)
   means the provider cannot perform that operation. Keep the machine and use
   its supported operations, or create a machine generation that supports the
   needed checkpoint flow. Do not treat Blaxel standby state as a named
   checkpoint that `vm restore` can consume.
5. If `vm tree` returns no workspaces or terminals after a successful create,
   check the transport and image before changing production environment
   variables. A Freestyle legacy `cmuxd-remote` machine is expected to expose
   only the legacy PTY/RPC surface. Production provider defaults and image
   variables are deployment-owner decisions, not client-side fixes.

## cmuxd versus cmux-tui

The legacy `cmuxd-remote` daemon serves a lease-authenticated WebSocket PTY
and RPC endpoint. It is retained for existing Freestyle snapshots and supports
shell attach and command execution. It does not own the cmux-tui workspace
journal, so Cloud tree actions and `vm terminal send|read|wait` cannot target it.

The cmux-tui remote daemon serves the `cmux-remote` protocol. Its daemon owns
workspaces and terminals, and the macOS client projects those resources into
the Cloud tree. A machine must be created with, or explicitly migrated to, an
image that starts cmux-tui before these operations can work. Existing
cmuxd-remote machines are not changed by this documentation and must be
recreated by the deployment owner when migration is approved.

## Scope and operational blocker

This matrix documents the current code and provider contracts. It does not
choose a production provider, image, or environment variable. Issue
[#11355](https://github.com/manaflow-ai/cmux/issues/11355) remains blocked on
that owner decision: either deploy a cmux-tui image and `cmux-remote` transport
in production, or implement and operate a cmux-tui bootstrap for the current
legacy Freestyle fleet. Vercel keeps Production, Preview, and Development
variables separate, and a variable change applies only to a new deployment;
see [Vercel environment variables](https://vercel.com/docs/environment-variables).
