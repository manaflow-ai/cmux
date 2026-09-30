# Agent recovery

`cmux recover` is the cmux front end for Subrouter's local recovery index. It
lists interrupted Claude sessions and their bounded context without changing
the current workspace:

```sh
cmux recover --query "Mac mini fleet"
cmux recover --session SESSION_ID --focus
cmux recover --session SESSION_ID --json
```

Without `--json`, the exact-session form creates a new isolated workspace. Its initial command is
`sr codex` with a bounded continuation prompt, so account routing and Codex's
cmux hooks remain active. The recovery command strips cmux control-plane
environment variables before invoking `sr`; credentials and transcript bodies
are not passed to the cmux socket.
