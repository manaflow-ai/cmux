# Secrets and the vault

Where cmux keeps API keys and other secrets, and how agents use a key without seeing it.

cmux never takes a secret on the command line. Each command below asks for the value without showing it, or reads it from stdin, and lists only names afterwards. Which one to use depends on where the agent runs.

## A key for an agent you added

An agent you added with cmux harness add keeps its key in the Keychain on macOS (secret-tool on Linux). Its profile holds only the item's name.

```bash
cmux harness secret set gateway ANTHROPIC_AUTH_TOKEN
```

## Secrets for Cloud machines

A repository lists the secrets its machine needs under [secrets] in .cmux/machine.toml. Store each value on your Mac. It stays in your Mac's Keychain and goes to the machine only over its own connection. Pass --repo OWNER/NAME to keep a value for one repository.

```bash
cmux cloud secret set DATABASE_URL
cmux cloud secret set DATABASE_URL --repo acme/api
cmux cloud secret ls
```

## The vault, for machines you add

Your vault keeps keys in your cmux account for the machines you add. A machine gets it when it joins with cmux machine add --vault, or when you grant it later. Each key says how agents get it:

- --host H: agents see a placeholder, cmux-secret://NAME. The machine puts the real value in only when a request header carries the placeholder to a host you listed. Other hosts, the URL, and the body never see it.
- --no-hosts: agents get a placeholder that is never replaced.
- --env: agents get the real value in their environment. This is weaker: an agent can read it.

```bash
cmux machine vault set MY_SERVICE_KEY --host api.example.com
cmux machine vault ls
cmux machine vault grant MACHINE
cmux machine vault revoke MACHINE
```

The vault never holds a Claude or Codex sign-in. Sign in on each machine through the agent's own flow.

| Where | What |
| --- | --- |
| [`cmux-tui/crates/acpmux/src/cli/harness_secret.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux/src/cli/harness_secret.rs) | cmux harness secret |
| [`cmux-tui/crates/cmux-tui/src/cli/cloud_secret.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-tui/src/cli/cloud_secret.rs) | cmux cloud secret |
| [`cmux-tui/crates/cmux-tui/src/cli/machine_join/vault.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-tui/src/cli/machine_join/vault.rs) | cmux machine vault |
| [`cmux-tui/crates/cmux-vault-egress`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-vault-egress) | The proxy that puts a vault value into allowed requests |

- [Run agents on your own API keys](own-keys.md)
- [Machines](machines.md)
- [Cloud machines](cloud.md)
- [How cmux NEXT fits together](architecture.md)
