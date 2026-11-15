# cmux keys: connect a provider once, mint scoped keys by API

`cmux keys` lets you and your agents make the keys a job needs, with no dashboard click per key. You connect a
provider once with one bootstrap credential, whose only power is creating narrower credentials. After that,
every key is minted by API, scoped to exactly what the job needs, given an expiry, and stored where it is
used. The design and its reasons are in cmuxterm-hq `docs/design/safe-keys.md`.

```
cmux keys connect cloudflare --account ACCOUNT_ID
cmux keys mint cloudflare-r2 --bucket NAME (--rw|--ro) [--ttl 90d] [--create-bucket] [--expire-objects-days N] --store SPEC...
cmux keys ls
cmux keys revoke ID
```

## Connect Cloudflare (once per account)

1. Cloudflare dashboard > Manage Account > Account API Tokens > Create Token > Custom token.
2. Permissions: **Account · Account API Tokens · Edit**. Account resources: the account. Nothing else.
3. On the Mac that runs your agents: `pbpaste | cmux keys connect cloudflare --account ACCOUNT_ID`.

`connect` checks that the token is active and can create tokens. It keeps the token only in the login
Keychain (service `cmux-key-provider`). Nothing ever prints it.

## Mint an R2 key

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

## Audit and revoke

`cmux keys ls` lists every connected provider and every minted key, read from `~/.config/cmux/keys.json`
(0600). For each key it shows the provider id, scope, created and expiry times, every place it was stored,
who asked (the agent session when known), and whether it is live, expired or revoked. It never shows a value.
`cmux keys revoke ID` deletes the token at Cloudflare, so every stored copy stops working.

To rotate a key, mint again with the same `--store` (that overwrites the secrets), then revoke the old id.
