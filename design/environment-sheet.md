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

The heading and the Cancel/Save row are fixed; only the fields between them scroll, so a long page
(many secrets, each unfolding its delivery) never pushes the actions out of the sheet. The sheet
grows with its content up to its height cap, then the fields scroll; the heading and actions never
move (gallery `secret-many-expanded`; `webviews/test/cloud-environment-sheet-geometry.test.ts`). One
box scrolls, `.env-scroll` (`min-height: 0`, `overflow-y: auto`) between the heading and the actions;
the sheet and the form clip (`overflow: clip`, never `hidden`, which script can still scroll), so no
field paints under the actions and the last Header line and Add stay reachable.

## Secret row

Secrets are write-only. The sheet shows a secret's name and where it is sent, never its value: GET
answers names, times and delivery targets, and anything else a reply carries is dropped on arrival
(`storedEnvironment`, and the daemon keeps only `name`, `updated_at`, `hosts`, `header`).

### Only where the service keeps it

A Cloud service without cmux-platform#1008 drops `hosts` and `header` and saves the value as a plain
variable on the machine, so a secret meant only for some hosts would reach the machine. Development,
staging and production deploy in turn, so the editor checks the service it talks to:

- **Before:** the Sent to and Header controls (and their note) show only on proof that the service
  keeps them: the environment reply declares `secret_routes: true`, or a stored secret already has
  `hosts`. An empty or absent field proves nothing. Without proof the secrets page is the plain list
  it was, and the one-host rule below is not checked, since the sheet has no way to pin a host
  there. (`secret_routes` is proposed to the platform; until it answers it, a stored secret with
  hosts is the only proof.)
- **After:** the PATCH reply must keep every route a save sent: each secret sent with `hosts` comes
  back with the same hosts (any order) and header (the default as absent). If one does not, the
  value was saved as a plain variable: the sheet stays open on what is now stored, Save does not
  report success, and the foot reads "This Cloud service didn't keep where the secret is sent, so it
  was saved as a plain variable on the machine. Remove it below, or try again later." The editor
  does not remove it by itself: a second write to a service that just misread the first is no safer,
  and the person decides.

### Delivery

A secret is delivered only as a vault edge grant to pinned hosts: sent only to those hosts, in a
request header the edge fills in, and its value never reaches the machine. So every secret needs at
least one host; a value the machine reads itself is a variable, not a secret. The platform refuses a
secret without hosts at boot too. `hosts` are 1 to 8 exact host names (no scheme, port, path or
wildcard). `header` is `{ name, format }` with `{value}` in `format`; absent means
`authorization: Bearer {value}`.

A secret stored without hosts (from before this rule) loads as it is and shows as invalid until it
gets a host; the editor never drops it.

Anatomy, top to bottom, inside one `.env-secret` block (8 px between lines, 16 px between secrets):

1. Name, value, remove: the row every value list has. An existing secret's name is read-only; its
   value field is empty and means "keep". A new secret needs a value.
2. **Sent to:** a label and one text field, inset to end under the value (the remove button's column
   stays clear). Hosts are typed as a comma or space separated list; the placeholder shows one
   ("Hosts, like api.example.com"). Case is folded and repeats are dropped on save.
3. **Header:** a disclosure line, on every secret, closed by default. Closed it reads
   `› Header  authorization: Bearer {value}` (the summary in the mono face, cut with an ellipsis).
   Open, it shows two fields side by side, Header name and Format, and the hint "{value} stands for
   the secret."
4. **Message:** one line under the row when something needs attention (below).

### States

| State | What shows |
| --- | --- |
| Rest | Lines 1 to 3, the header closed with its summary. |
| New, blank | A row just added, with nothing typed: Sent to is empty with its placeholder and not flagged yet. Save still stops on it. |
| No hosts | A secret with a name, a value or a stored copy and an empty Sent to, once Sent to does not have focus (a stored one at load): Sent to is `aria-invalid`, the message reads "A secret needs at least one host. For a value the machine reads itself, use a variable." in the danger text color, and Save stops with the same sentence at the foot. |
| Hover | Fields and buttons take the sheet's hover fill; nothing moves. |
| Focus | The field's focus ring. While Sent to has focus its text is never flagged, so a half-typed name is not an error. |
| Header open | The disclosure mark turns 90 degrees and the two fields unfold under it. |
| Invalid host | On blur, or on Save: Sent to is `aria-invalid`, the message line reads "Use up to 8 host names like api.example.com, with no scheme, port, path or wildcard." in the danger text color, and Save stops with the same sentence at the foot. |
| Invalid header | A header name that is not a lowercase token of up to 64 characters (typing folds case), or a format without `{value}` or over 256 characters: both header fields are `aria-invalid`, the message reads "Name the header and include {value} in its format.", Save stops. |
| Framing header | `host`, `content-length`, `transfer-encoding`, `connection` or `upgrade`: the message reads "That header carries the request itself (like host or content-length). Use another, such as authorization.", Save stops. The platform's `cloud_environment.invalid_secret_route` shows the same sentence. |
| Delivery changed, value empty | A secret that already has hosts, with its hosts or header changed, and its value left empty: no message. Save sends where it goes and keeps the sealed value. |
| First hosts, value empty | A secret stored without hosts given its first host with its value left empty: the value field is `aria-invalid`, the message reads "Type the value again to send this secret to these hosts.", Save stops. The platform can't move such a secret's value to hosts without it (`secret_value_required`). |
| Invalid value | A secret whose value has a line break, a control or a non-ASCII character (it goes in a header): the value field is `aria-invalid`, the message reads "A secret sent to hosts goes in a header: use plain ASCII text, spaces and tabs, with no line breaks. The header format follows the same rule.", Save stops. The platform's `cloud_environment.invalid_value` shows the same sentence. |
| Saved | The sheet closes, as for every other change. Reopening shows the stored hosts and header and an empty value. |

### Motion

Every line that appears or goes (the header fields, the message) folds by its own
height (`.env-fold`: `grid-template-rows` 0fr to 1fr with opacity): opening over
`--cmux-motion-standard`, closing over `--cmux-motion-quick`, easing out. The secrets and the Add
button below travel with the fold in the same frames, so nothing jumps or pops in after it ends.
Reduced or off motion opens and closes at once.

### What goes over the wire

`set_secrets` gets one entry per secret whose value, hosts or header changed, and none for the
others. Each entry states where the secret goes in full; only `value` may be left out:

- `{ name, value?, hosts?, header? }`. No `value` keeps the stored sealed value and changes only
  where it goes, for a secret that already has hosts; a secret stored without hosts needs its value
  with its first hosts; the platform answers 400 `cloud_environment.secret_value_required` when no secret
  by that name exists (one removed elsewhere since the sheet opened), shown as "a new secret needs a
  value".
- Every entry carries its `hosts`, never "unchanged": the editor refuses a secret without hosts
  before Save, and a value-only change still sends its hosts.
- No `header` means `authorization: Bearer {value}`, never "unchanged": a custom header switched
  back to the default is sent without `header`, and the platform answers a default header as absent.
- A header goes only with hosts, which every saved secret has.

The rules match the platform's (cmux-platform#1008): hosts as above, a lowercase header name, the
reserved framing headers, `{value}` in a format of at most 256 characters, and printable ASCII
(spaces and tabs allowed) in a secret's value and in the header format. Its refusals
`secret_value_required`, `invalid_secret_route` and `invalid_value` map to the editor's own sentences; a schema 400
the editor's checks already stop never reaches it.

## Variants considered for the secret row

- **A, inline (picked):** Sent to always under the value, the header as a folded line under it. Every
  secret answers "where does this go" at a glance, the default needs no clicks, and the header stays
  out of the way until someone needs it.
- **B, chips:** each host a removable chip with an add field. Clearer per-host removal, but chips
  wrap unpredictably in the 560 px sheet and grow the row with every host; a plain list reads as
  well for 1 to 8 names.
- **C, compact:** one line per secret with an "Edit delivery" popover. Densest, but it hides the
  delivery behind a click and puts a popup on a sheet.

The gallery (`cloud.environment-sheet`) shows the picked design in its states: `secrets`,
`secret-hosts` (default and custom header), `secret-header-open`, `secret-invalid-host`,
`secret-no-hosts` (a secret stored without hosts, invalid at load), `secret-new-no-hosts` (a new
secret with no host, Save refused), `secret-delivery-edit` (a host added to a secret that has hosts,
value left empty) and `secret-first-hosts` (a secret stored without hosts given its first host,
asking for its value) and
`secret-many-expanded` (nine secrets, every header open, the fields scrolling between the fixed
heading and actions). Gallery variants are states of the real component, never copies of it
(`webviews/src/gallery/ENTRIES.md`), so B and C live only in this section.

## Never

- A secret value read from the server, kept in state, or drawn.
- A `set_secrets` entry that leaves out hosts or header to mean "unchanged".
- A header line that appears or a message that appears without its fold.
- A secret saved without a host, or one stored without hosts dropped instead of shown as invalid.
- A secret stored without hosts moved to hosts without its value.
- Delivery controls on a service that has not shown it keeps them, or a save reported done when the
  reply dropped a route.
- Actions pushed out of the sheet by its content.
