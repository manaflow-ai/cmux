# Settings > Keys: keys agents keep, and the keys they ask you for

Leo, 2026-11-15: "can you do the keys without cloudflare? im just saying like as an app feature
letting agents safely write keys and store them or enter them jnto whatever". Agents store and use
keys with `cmux keys put/generate/use/write/fill` (cmux-tui `cli/key_broker.rs`) without a person
in the loop. When an agent needs a key only the person has, it runs `cmux keys request NAME
--purpose TEXT [--hosts h1,h2] [--ttl 90d]` and waits. This page is where that request is answered
and where every key is listed. A value never shows on this page, in a notification, in a log or in
the agent's answer.

Surfaces:

- Settings > Keys (`webviews/src/pages/settings/components/KeysCard.tsx`, rows in `keys.ts`, gallery
  `pages.settings-keys` in `keys.gallery.ts`). Sidebar: Accounts and Devices > Keys, symbol `key`,
  after Accounts. Deep link `#/settings/keys`.
- The request banner (`CmuxNextKeys/KeyRequests+Control.swift`, ``KeyRequests/postBanners(on:)``).
- The control method `keys.request` and the page ops `cmux.settings.keys.list|answer|decline|revoke`
  (`SettingsKeys.swift`, ``KeyRequests``, ``KeysCLI``).

## References

- `cmux/live/settings-accounts-section-opened-by-cli`: the Accounts card is the closest sibling. A
  provider row with a quiet status on the right (dot and word), Get Key and Add Key… under it. Keys
  reuses that status (`accounts-status`, `accounts-dot`) and the Accounts paste form's private field.
- `cmux/live/settings-cloud-environment-editor-back-chevron`: Network secrets as a row with a one-line
  summary under the title. A key row reads the same way: name, then one muted line of facts.
- `claude/live/approvals-question-card-with-choices` and `cmux/live/approvals-needs-input-choice-keyboard-enter-bug`:
  an agent's question is a card with the question first, then the answer controls, then Skip and
  Submit on one line. A key request has the same order: what, why, who, then field, Store, Decline.
- `cmux/live/approvals-allow-deny-buttons-shortcut-hints`: the primary answer is the solid button;
  the refusal is a plain button beside it, never red.
- Settings > Privacy and Security > Shared Links (`SharedLinksCard.tsx`): Revoke is a ghost danger
  button at the row's end, and a destructive action asks first, inline, in the Accounts form shape.

## Layout

Two group cards, in the Settings card look (transparent groups, hairline rows, no fills).

1. **Key Requests** (only while one waits; `data-card="keyRequests"`). One row per request, oldest
   first:
   - Title: the key's name in the mono face (`keys-name`).
   - The purpose, in primary ink, wrapping (`keys-purpose`, `overflow-wrap: anywhere`), selectable:
     the agent's own words.
   - One muted line: `Asked by <agent>` (the agent's product and the start of its session id, from
     the CLI's `CLAUDE_CODE_SESSION_ID=…`; a user name for `user=…`).
   - One muted, selectable line: `For <host, host>` when the request names sites.
   - One line: the private field (`type=password`, `autocomplete=off`, `spellcheck=false`, max
     320 px, placeholder "Paste the value"), Store (solid, off while the field is empty), Decline.
   - An error line in danger ink under it when the host refused.
2. **Keys** (`data-card="keys"`). One row per key: live first, then expired, then revoked; newest
   first within each.
   - Title: the label, then the name in mono when it differs.
   - The purpose when there is one (selectable).
   - One muted, selectable line of values: `For <hosts>` or `Any site` · `Used in <stores and uses>`
     or `Not used yet` · `Expires <date>` or `Doesn’t expire`.
   - One muted line: `Added by <agent> (<who asked>)`. Every description line fits 60 characters in
     every language (rowSummary.test.tsx); the long values sit on the selectable line.
   - At the row's end: the status (dot and word: Active in success, Expired in attention, Revoked
     neutral at 40 %), then Revoke (ghost, danger) unless already revoked.
   - Revoke opens the confirm inline under the row: "Revoke NAME?", what happens (a local key's
     value is deleted from this Mac, copies written elsewhere keep working until removed; a provider
     key is deleted at the provider and stops working everywhere), Revoke and Cancel.

## States

| State | What shows |
| --- | --- |
| Loading | The card title only (the section read fills it before the first frame, as every card). |
| Empty | One muted line: "No keys yet. An agent adds one with `cmux keys put NAME`." |
| Unavailable | One muted line: "Keys can’t be read in this build." Requests still show. |
| Request waiting | Key Requests above Keys; the banner was posted. |
| Typing | The field masks; Store turns on. |
| Storing | Store and Decline off; the field is already empty. |
| Store refused | The value goes back into the field (no retyping), the reason under it. |
| Stored | The request leaves; the key appears at the top of Keys. |
| Declined | The request leaves; the agent hears `declined`. |
| Revoke confirm | Inline confirm under the row. |
| Revoked | The row moves to the bottom, status Revoked, no Revoke button. |

## Request lifecycle

- `keys.request` adds the request in memory (at most 16; the 17th pushes out the oldest, which ends
  `cancelled`; a new ask for the same name replaces the old one, which ends `cancelled`).
- One banner per request: title "<agent> asks for a key", body "NAME: purpose". Posting never takes
  focus; clicking it opens Settings > Keys. It is withdrawn when the request ends.
- Store pipes the value to `cmux keys put NAME --purpose … --hosts … --ttl … --replace --from-person
  --asked-by <requester> --json` on stdin, and only after that succeeds answers the agent
  `{stored: true, name}`. A failed put leaves the request waiting.
- The request ends `cancelled` when the asker's connection closes (Ctrl-C) or after a week.
- An open Settings page reads the list again on `cmux.settings.keys.changed` (a revision number,
  no text), so a request that arrives while Keys is open shows at once. Nothing polls.

## Browser fill

`cmux keys fill` sends `browser.page.fill|type` with `secret: true` (and `secret_hosts`). The agent
cursor draws bullets, the answer leaves out `value`, and when `secret_hosts` is set the tab's page
(its own URL, else the snapshot's) must be on one of those sites or under one, or the call fails
with `secret_host_mismatch` before any page script runs.

## Tokens

Ink `--text`, `--muted-text`; danger `--danger`; status dots `--success`, `--warning` (via
`devices-status`); hairlines `--border`; field `Input` (filled, `--input-bg`); mono
`--font-mono`; sizes `--text-detail`. No new colors, no fills on rows or cards: the window's
translucent material shows through as on every Settings card.

## Copy

Plain words, sentence case for help, Title Case for card titles and buttons (Settings convention):
Keys, Key Requests, Store, Decline, Revoke, Cancel. Strings live in
`CmuxNextSettingsWindow/Localizable.xcstrings` (`settingsPage.keys.*`), the category title in
`CmuxNextSettings` (`settings.category.keys`), the banner in `CmuxNextKeys/Resources/Keys.xcstrings`.

## Gallery variants (`pages.settings-keys`)

1. `shipped`: one request and three keys (live, expired, revoked).
2. `empty`: no keys, no requests.
3. `many`: seven keys with stores, uses, generated and typed keys, expired and revoked.
4. `long-purpose`: two requests, one with a long name, purpose and three hosts.
5. `revoke-confirm`: the inline confirm open.
6. `typed`: a value typed into the request (masked; Store on).
7. `unavailable`: this build cannot list keys.
