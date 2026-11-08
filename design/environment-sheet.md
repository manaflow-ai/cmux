# Edit cloud environment: the sheet

The sheet that edits one Cloud environment's name, network, secrets, setup script and variables:
`webviews/src/pages/cloud/EnvironmentSheet.tsx`, `EnvironmentFields.tsx`, `environmentModel.ts`,
`environmentStore.ts`, `environment.css`. The chat hosts it through
`agent-session/acpmux/CloudEnvironmentEditor*.tsx`; it reads and writes
`/v1/cloud-environments/:id` through `cloud.environment.*` and the daemon's `cloud-environment`.
Product rules for Cloud live in leo-workspace `design/cloud.md`; this page is the sheet's anatomy.

Leo, 2026-11-08: "And likewise for cloud, you know, there's the auto mode and then the more granular
optional mode if you want ... it's interesting if you could, in fact, edit your cloud thing".

## Pages

An overview (the name, then one drill-in row per section with a one-line summary) and four drill-in
pages: Network access, Network secrets, Setup script, Environment variables. The back chevron
returns to the overview with the same draft. Save sends only what changed; Cancel and Escape write
nothing and drop every typed secret value.

## Secret row

Secrets are write-only. The sheet shows a secret's name and where it is sent, never its value: GET
answers names, times and delivery targets, and anything else a reply carries is dropped on arrival
(`storedEnvironment`, and the daemon keeps only `name`, `updated_at`, `hosts`, `header`).

A secret goes one of two ways (the vault's edge grants):

- **No hosts:** an environment variable on the machine, as before.
- **Hosts:** sent only to those hosts, in a request header the edge fills in; the value never enters
  the machine. `hosts` are 1 to 8 exact host names (no scheme, port, path or wildcard). `header` is
  `{ name, format }` with `{value}` in `format`; absent means `authorization: Bearer {value}`.

Anatomy, top to bottom, inside one `.env-secret` block (8 px between lines, 16 px between secrets):

1. Name, value, remove: the row every value list has. An existing secret's name is read-only; its
   value field is empty and means "keep".
2. **Sent to:** a label and one text field, inset to end under the value (the remove button's column
   stays clear). Hosts are typed as a comma or space separated list; the placeholder says what empty
   means ("No hosts: an environment variable"). Case is folded and repeats are dropped on save.
3. **Header:** a disclosure line, present only once Sent to has a host. Closed it reads
   `› Header  authorization: Bearer {value}` (the summary in the mono face, cut with an ellipsis).
   Open, it shows two fields side by side, Header name and Format, and the hint "{value} stands for
   the secret."
4. **Message:** one line under the row when something needs attention (below).

### States

| State | What shows |
| --- | --- |
| Rest, no hosts | Lines 1 and 2; Sent to is empty with its placeholder. The header line is folded away and inert. |
| Rest, hosts | Lines 1 to 3, the header closed with its summary. |
| Hover | Fields and buttons take the sheet's hover fill; nothing moves. |
| Focus | The field's focus ring. While Sent to has focus its text is never flagged, so a half-typed name is not an error. |
| Editing hosts | Typing the first host unfolds the header line; clearing the last one folds it. |
| Header open | The disclosure mark turns 90 degrees and the two fields unfold under it. |
| Invalid host | On blur, or on Save: Sent to is `aria-invalid`, the message line reads "Use up to 8 host names like api.example.com, with no scheme, port, path or wildcard." in the danger text color, and Save stops with the same sentence at the foot. |
| Invalid header | A header name that is not a token, or a format without `{value}`: both header fields are `aria-invalid`, the message reads "Name the header and include {value} in its format.", Save stops. |
| Delivery changed, value empty | An existing secret whose hosts or header differ from the stored ones, with no new value: the message (secondary text, not an error) reads "Type the value again to change where this secret is sent."; Save stops with the same sentence until the value is typed. The platform's `set_secrets` writes a value with its delivery and has no metadata-only form. |
| Saved | The sheet closes, as for every other change. Reopening shows the stored hosts and header and an empty value. |

### Motion

Every line that appears or goes (the header line, the header fields, the message) folds by its own
height (`.env-fold`: `grid-template-rows` 0fr to 1fr with opacity): opening over
`--cmux-motion-standard`, closing over `--cmux-motion-quick`, easing out. The secrets and the Add
button below travel with the fold in the same frames, so nothing jumps or pops in after it ends.
Reduced or off motion opens and closes at once.

### What goes over the wire

A secret with a value goes in `set_secrets` as `{ name, value, hosts?, header? }`: `hosts` when it
has any, `header` only when it differs from the default. A value retyped on a secret that has hosts
carries its current hosts and header, so rotating a value never drops its delivery. A secret left
empty is not sent.

## Variants considered for the secret row

- **A, inline (picked):** Sent to always under the value, the header as a folded line under it. Every
  secret answers "where does this go" at a glance, the default needs no clicks, and the header stays
  out of the way until someone needs it.
- **B, chips:** each host a removable chip with an add field. Clearer per-host removal, but chips
  wrap unpredictably in the 560 px sheet and grow the row with every host; a plain list reads as
  well for 1 to 8 names.
- **C, compact:** one line per secret with an "Edit delivery" popover. Densest, but it hides the
  delivery behind a click and puts a popup on a sheet.

The gallery (`cloud.environment-sheet`) shows the picked design in its states: `secrets` (no hosts),
`secret-hosts` (default and custom header), `secret-header-open`, `secret-invalid-host` and
`secret-retype`. Gallery variants are states of the real component, never copies of it
(`webviews/src/gallery/ENTRIES.md`), so B and C live only in this section.

## Never

- A secret value read from the server, kept in state, or drawn.
- A delivery change saved without its value.
- A header line that appears or a message that appears without its fold.
