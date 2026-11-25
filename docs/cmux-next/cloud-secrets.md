# Cloud secrets

`cmux cloud secret set NAME` keeps a value in this Mac's Keychain. `cmux cloud deliver-secrets --target
machine:<id>` (also a step of `cmux vm ready`) seals the values a machine's `.cmux/machine.toml` declares to that
machine's daemon key and writes them to `~/.config/cmux/machine-secrets.env` there. No value crosses cmux's
servers, a file API, a terminal or a log. Anything running on the machine can read a value written there, so give
agents scoped, revocable credentials.

## Claude setup token

`claude setup-token` prints a long-lived Claude Code token. Keep it on your Mac:

```
claude setup-token                              # sign in, copy the token it prints
cmux cloud secret set CLAUDE_CODE_OAUTH_TOKEN   # paste it at the hidden prompt
```

Delivery sends it to every machine whose machine config has applied, whether or not that config declares it,
so Claude Code on the machine is signed in as you. The machine keeps it in shells even when its config doesn't
name it. A token stored with `--repo OWNER/NAME` goes only to a delivery run with that `--repo`; when a machine
says it holds a repository you stored a token for, delivery asks for `--repo` instead of sending the global one.
cmux never stores the token on its servers. Remove it with `cmux cloud secret rm CLAUDE_CODE_OAUTH_TOKEN`; the
next delivery leaves it out.

Personal and per-chat values set from the Cloud service are planned
([plans/cmux-next/cloud-secrets.md](../../plans/cmux-next/cloud-secrets.md)).
