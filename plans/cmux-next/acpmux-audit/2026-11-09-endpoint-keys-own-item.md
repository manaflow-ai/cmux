# Notice to PL-acpmux: an endpoint harness's key reaches only its own URL (2026-11-09)

cmux#39341 (Settings › Agents › Endpoint tab, lane api-and-open-models). Rule: a key reaches only
the URL it was stored with.

- Each endpoint profile version stores its key in its own Keychain item,
  `cmux-harness/<id>/<KEY>.<generation>`; the profile names that item. Add and replace store the key
  first and publish the profile last (one atomic rename, under `.endpoint-add.lock`). A failed
  publish deletes only the new item; a replace deletes the old item after the swap.
- Every endpoint Keychain read goes through `byo_endpoint::endpoint_keychain_lookup`: a
  `cmux-harness` item is read only by its exact `<id>/<KEY>[.<gen>]` account. A caller's
  `keychainItem` / `--keychain-item` may not name the `cmux-harness` service in any spelling.
  `resolve_env_refs` routes through it whenever the env carries the endpoint marker.
- Every endpoint harness starts without an inherited `CMUX_BYO_API_KEY`; an Anthropic one also
  without inherited `ANTHROPIC_*` and Claude provider switches (`clear_inherited`, `clears` for
  `login_env::ChildEnv`). A keyless OpenAI profile has no `apiKey`.
- Remove keeps the key so Undo restores a working endpoint; `forgetKey` (`--forget-key`) deletes
  the profile's own items and reports a failed delete as `keyError`. Restore runs under the add lock.
- `cmux harness secret set` refuses an endpoint harness; a new key is
  `cmux harness add ID ... --key --force` or the Settings form.
- Older `cmux-harness/<id>/<KEY>` items (no generation) are kept, since a backup may name them;
  only `--forget-key` deletes them.
