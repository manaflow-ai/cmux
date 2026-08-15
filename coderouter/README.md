# coderouter CLI

coderouter - route Codex/Claude Code traffic across multiple ChatGPT Pro/Claude Max/OpenCode subscriptions and API keys.

```bash
cr add
cr codex
cr pi
cr naked
```

`coderouter` and `cr` are equivalent executable names. With no command, they
show the account and usage summary. Agent routing is always explicit.

## Commands

```text
cr                           account and usage summary
cr codex [arguments...]       Codex through coderouter
cr opencode [arguments...]    OpenCode through coderouter
cr pi [arguments...]          Pi through coderouter (experimental)
cr naked [arguments...]       ordinary Codex, with coderouter bypassed
cr direct [arguments...]      alias for naked
cr add                        add Codex or OpenCode Go interactively
cr remove [account] [--yes]   remove a subscription
cr accounts                   list available subscriptions
cr usage                      show quota state
cr doctor                     diagnose login and the Vercel data plane
cr login / cr logout          manage this machine's coderouter session
cr login --device-auth        copy a code into coderouter.dev/authorize
cr capabilities --json        report credential-free CLI capabilities
cr org current                show the active organization
cr org list                   list authorized coderouter organizations
cr org switch <name-or-id>    switch organization and routing credentials
cr upgrade                    open cmux Pro and Team pricing
```

Organization switching is fail-closed. The server returns only organizations
where the signed-in user can use or manage coderouter, and the CLI persists the
new scope only after receiving a new organization-scoped route token.

The Ratatui add flow supports direct Codex OAuth/PKCE and OpenCode Go device
authorization. Direct Codex authentication has an explicit portable-PTY
fallback through the official CLI. Normal agent credentials are untouched.

The production control plane is `https://coderouter.dev`. coderouter uses a
separate session config and never overwrites normal agent configuration.
`CODEROUTER_API_URL` can override the origin for staging and loopback tests.

## cmux hosted handoff

When cmux starts a routed agent, it first arms its authenticated control socket
for the exact signed CodeRouter process. CodeRouter connects to that socket
after exec and performs a bounded protocol-v2 two-step handshake. It sends
`coderouter.handoff.begin`, validates the server's canonical 32-byte
base64url challenge, then sends `coderouter.handoff.complete` with the exact
challenge text on the same socket. The server then returns a team-scoped
one-use `crh_` lease with its team and expiry metadata.
It exchanges that lease once at the hosted origin and keeps the returned `crt_`
route credential in memory for the child process. The private launch form
carries only an absolute socket path and a SHA-256 team binding. It never
carries the team ID, lease, Stack credentials, or route token.

Each LF-terminated callback frame is limited to 4 KiB, including the LF, and
connect, both writes, and both reads share one 25-second deadline. CodeRouter
requires EOF after the final response, then closes the socket and does not pass
any handoff variables to the provider child. It compares the socket team and
the hosted exchange team with the same binding before the child can start.
Missing, malformed, expired, consumed, revoked, or team-mismatched handoffs
fail closed; the CLI does not fall back to a saved login. Obsolete FD or
environment socket markers also fail closed on routed commands. A legacy
one-step lease response is rejected.

The exchange origin is pinned to `https://coderouter.dev` in production. The
dedicated `CODEROUTER_HANDOFF_TEST_ORIGIN` variable permits an HTTP loopback
origin only in debug/test builds. Normal API URL and data-directory variables
never select the handoff origin. Help, version, and capability commands remain
credential-free and do not connect to the handoff socket. Capability protocol
version 2 advertises the `cmux-socket-v1` authentication mode.

## Privacy-safe analytics

Signed-in CLI commands send a short, best-effort lifecycle event to the
authenticated CodeRouter server. The closed schema contains only coarse
command/agent/mode/outcome/failure/exit/duration/context categories and the CLI
version. It never includes command arguments, prompts, output, credentials,
tokens, account/team/user identifiers, names, labels, email, paths, URLs, or
free-form errors. Delivery cannot fail a command and uses a 200 ms deadline.

Disable CLI analytics with either:

```bash
export DO_NOT_TRACK=1
# or
export CODEROUTER_TELEMETRY_DISABLED=1
```

## Routing

The CLI routes directly to the Vercel data plane at `coderouter.dev`. It does
not install Subrouter, a local daemon, Go code, or GCP tooling.

`cr pi` creates an ephemeral Pi provider extension for the current process. It
captures the route token during extension startup and immediately removes it
from Pi's process environment before tools can inherit it. It never writes the
token to Pi config and leaves normal providers, settings, extensions, and
sessions untouched.
