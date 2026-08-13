# coderouter CLI

Run CodeRouter with `npx coderouter` or `npx coderouter@latest`.

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
