# cmux keys: store a key once, enter it anywhere by name

`cmux keys` lets you and your agents keep the keys a job needs and put them where they're used, without the
value ever showing up in a chat, a transcript, a log or a command line. A key can come from any provider: one
an agent got from a provider's API or CLI, one the person pastes once, or one cmux generates. Cloudflare is
also a provider cmux can mint scoped keys from by API. The design and its reasons are in cmuxterm-hq
`docs/design/safe-keys.md`.

```
<command that prints a key> | cmux keys put NAME --purpose TEXT [--hosts H,H] [--ttl 90d]
cmux keys generate NAME [--bytes 32] [--format base64url|hex|alnum]
cmux keys request NAME --purpose TEXT             # asks the person in the cmux app
cmux keys use NAME[=VAR]... -- CMD [ARGS...]      # CMD gets the key in its env
cmux keys write NAME --to TARGET...               # a GitHub secret, a 0600 file, a config field
cmux keys fill NAME --selector CSS [--tab TAB]    # a field in a cmux browser tab
cmux keys ls
cmux keys rm NAME
```

## Store a key

The value comes on stdin only, never as an argument. At a terminal, `put` asks for it with a hidden prompt.

```
<provider CLI that prints a token> | cmux keys put DEPLOY_TOKEN --purpose "deploy the docs site" --hosts api.example.com
curl -s ... | jq -r .token | cmux keys put UPLOAD_TOKEN --purpose "upload release files" --ttl 30d
cmux keys generate WEBHOOK_SECRET --purpose "sign webhook payloads"
```

- NAME is an env name: upper case letters, digits and `_`.
- The value goes into the OS secret store: the login Keychain on a Mac, the Secret Service on Linux
  (`secret-tool`). A machine with neither refuses; there's no file fallback.
- `--hosts` scopes the key: `fill` types it only into pages on those hosts or their subdomains, and
  `write --to vault:VAR` keeps it as a placeholder the egress proxy fills only toward those hosts.
- `--ttl` sets an expiry; an expired key is refused everywhere until you `put` it again with `--replace`.
- `put` refuses a name that's already stored. `--replace` stores the new value; the old copies `write` made are
  listed as stale until you write them again.

## Ask the person for a key

When only the person has the key (a dashboard shows it once, it's their account), ask for it:

```
cmux keys request EVAL_API_KEY --purpose "run the evals in this repo" --hosts api.example.com
```

The cmux app shows the ask in Settings > Keys and notifies the person, without taking focus. It names the key,
the purpose, the hosts and the agent that asked. The person pastes the value into a secure field there, and
cmux stores it. The value never passes through the chat. The command waits for the answer (15 minutes by
default, `--timeout 2h` for longer) and prints the stored record, or exits 1 if the person declines.

## Use a key

**As env for one command.** The command gets the value; what it prints has the value replaced by
`<concealed by cmux keys>`. `--no-mask` passes output through untouched, for an interactive
command that needs a terminal.

```
cmux keys use DEPLOY_TOKEN=API_TOKEN -- ./deploy.sh
cmux keys use UPLOAD_TOKEN --env AUTH_TOKEN GH --env GH_TOKEN -- ./release.sh
```

The exit code is the command's own.

**Copied somewhere.** Repeat `--to` to write several places. Files are written as 0600, through a temporary
file and a rename. A link or a folder at the path is refused.

| target | writes |
|---|---|
| `gh-secret:OWNER/REPO:SECRET` | a repository Actions secret, through `gh secret set` on stdin |
| `gh-secret:OWNER/REPO@ENV:SECRET` | an environment's secret |
| `keychain:SECRET` or `keychain:OWNER/REPO:SECRET` | this Mac's cloud secrets, which `cmux vm deliver-secrets` delivers to machines |
| `vault:VAR` | this machine's kept keys: agents the daemon starts get it (a host-scoped placeholder when the key has `--hosts`) |
| `file:PATH` | the value alone |
| `json:PATH#a.b` | that field of a JSON file (other fields kept) |
| `toml:PATH#a.b` | that field of a TOML file (comments and layout kept) |
| `env-file:PATH#VAR` | the `VAR=` line of an env file, quoted when needed |

**Into a field.** `fill` types the key into a field of a cmux browser tab: `--tab` names the tab (default the
browser nearest the caller), `--selector` is CSS or a snapshot ref like `e3`, `--type` types it key by key. A
key with `--hosts` is refused on any other page, before anything is typed. The agent cursor shows the field as
a secret, and the app's answer leaves the value out.

```
cmux keys fill DEPLOY_TOKEN --selector '#api-key'
```

In a cmux chat, the `keys_fill` tool does the same, and with `target: "app"` it types a key into a desktop app
through Computer Use (`tool: "type_text"` or `"set_value"`, and that tool's own arguments without the text).
`keys_list` and `keys_write` are the MCP forms of `ls` and `write`. All of them take a key's name, never its
value.

## Audit and remove

`cmux keys ls` lists every key, read from `~/.config/cmux/keys.json` (0600), and Settings > Keys shows the same
list. For each key it shows the name, purpose, hosts, who stored it and which agent asked, when it expires,
every place a copy was written, every place it was entered (env for which command, which page and field),
and whether it's live, expired or removed. It never shows a value.

`cmux keys rm NAME` deletes the value from the OS store. Copies `write` made stay where they are, and `rm` lists
them: rotate the key at its provider to kill those.

## What this protects, and what it doesn't

It keeps values out of transcripts, logs, replies and a model's context, and keeps a scoped key off the wrong
site. It isn't a wall against an agent that sets out to read a value: a command run with `use` gets the
value, and the OS store answers any process of this user.

## Mint scoped keys from Cloudflare

For Cloudflare, cmux can make the key itself. You connect the account once with one bootstrap credential,
whose only power is creating narrower credentials. After that, every key is minted by API, scoped to what the
job needs, given an expiry, and stored where it's used.

```
cmux keys connect cloudflare --account ACCOUNT_ID
cmux keys mint cloudflare-r2 --bucket NAME (--rw|--ro) [--ttl 90d] [--create-bucket] [--expire-objects-days N] --store SPEC...
cmux keys revoke ID
```

### Connect Cloudflare (once per account)

1. Cloudflare dashboard > Manage Account > Account API Tokens > Create Token > Custom token.
2. Permissions: **Account · Account API Tokens · Edit**. Account resources: the account. Nothing else.
3. On the Mac that runs your agents: `pbpaste | cmux keys connect cloudflare --account ACCOUNT_ID`.

`connect` checks that the token is active and can create tokens. It keeps the token only in the login
Keychain (service `cmux-key-provider`). Nothing ever prints it.

### Mint an R2 key

```
cmux keys mint cloudflare-r2 --bucket cmux-ci-handoff --rw --ttl 180d \
  --create-bucket --expire-objects-days 1 --store gh-secret:manaflow-ai/cmux:CI_HANDOFF_R2
```

- With `--create-bucket` or `--expire-objects-days`, cmux mints a 15-minute R2 admin token, makes the bucket
  if it is missing, and sets its lifecycle, then revokes that token. `--expire-objects-days` replaces the
  bucket's whole lifecycle with that one rule.
- The key it stores is an account-owned token with only *Workers R2 Storage Bucket Item Write* (`--rw`) or
  *Read* (`--ro`) on that one bucket. It expires after `--ttl` (default 90d, at most 365d).
- R2's S3 pair comes from that token: `PREFIX_ACCESS_KEY_ID` is the token id, and `PREFIX_SECRET_ACCESS_KEY`
  is the SHA-256 of its value.

Store specs (repeat `--store` to put the same key in several places):

| spec | stored as |
|---|---|
| `gh-secret:OWNER/REPO:PREFIX` | repository Actions secrets, via `gh secret set` on stdin (your `gh` needs secrets write) |
| `gh-secret:OWNER/REPO@ENV:PREFIX` | an environment's secrets |
| `keychain:PREFIX` or `keychain:OWNER/REPO:PREFIX` | this Mac's cloud secrets, the store `cmux cloud secret set` uses, so `cmux vm deliver-secrets` delivers it to machines |
| `vault:PREFIX` | this machine's kept keys (`acpmux machine vault keep NAME --env`, cmux#43439): agents the daemon starts get them. `--env`, because an S3 pair signs requests locally (SigV4), so the egress proxy has no placeholder to fill |

If a store fails, the new key is revoked at once and nothing is recorded as live.

`cmux keys revoke ID` deletes a minted token at Cloudflare, so every stored copy stops working. To rotate a
minted key, mint again with the same `--store` (that overwrites the secrets), then revoke the old id.

### Mint from a Linux machine

The bootstrap token stays in the Mac's Keychain. A Linux machine that is an acpmux peer of that Mac asks the
Mac's broker for a key instead, and gets back only the scoped key:

```
cmux keys mint cloudflare-r2 --via MAC --bucket cmux-ci-handoff --ro --ttl 30d --store vault:CI_HANDOFF_R2
```

- The ask goes to this machine's acpmux, then over the peer link to the Mac (`_acpmux/keys_mint`). The Mac
  takes it only from a peer that proved its peer token or a `client` device credential, as Computer Use does.
- The ask carries only the key's scope (bucket, access, ttl, account, bucket setup). The Mac mints with
  `cmux keys mint ... --reply-to-machine NAME` and sends back the key's id, scope, expiry and its S3 pair,
  and nothing else. The bootstrap never leaves the Mac.
- This machine stores the pair in its own `--store`s (usually `vault:`) and records the key in its own
  audit with `via`. The Mac's audit lists the key as delivered to `machine:NAME`. Revoke it on the Mac.
