# Computer Use readiness experiment

Turn on **Settings > Advanced > Labs > Show Preview Features**, then run:

```sh
cmux --json computer-use readiness
cmux --json computer-use readiness --machine studio
```

This read-only experiment asks the same Computer Use worker that handles agent
calls for its current OS grants. It never probes permissions from the shell
process, requests consent, starts a screenshot, or authorizes a target app.
The local app's Labs switch gates both local and remote reports. Turning it off
disables the command again; ordinary `computer-use status` is unchanged.

The worker's existing status is preserved, including its machine, platform,
mode, and denied apps. An additional `readiness` object contains:

- `scope: os_permissions` and `source: worker_status`.
- `ready: true` only when accessibility, screen capture, and input are each
  `granted` or `not_needed` according to that worker.
- `state: needs_permission` and `missing` for denied grants, or `state: unknown`
  and `unknown` for missing, malformed, or unrecognized grants.
- `target_authorization: unchanged`: OS readiness does not establish access to
  any particular app, window, session, or remote machine.

Exit 0 means the worker reports its OS grants ready. Exit 1 means a grant is
missing or unknown, the experiment is off, or settings/the worker could not be
read. Worker-off, tool-refusal, and transport errors retain their existing
error codes. No result is cached. Grant missing OS permissions through the
normal Computer Use setup flow, then rerun this command.

This first slice does not bootstrap login, install a helper, change its signing
identity, or make protected windows controllable. It has no GUI changes and
uses the existing default-off Labs switch.
