# ChatGPT browser-use agent text formats

> Reference study, kept for the record. cmux does not implement this format; the tools it cites were removed with the dialects and remain in git history.

Behavioral spec of the text that the ChatGPT for Chrome / Codex browser-use
runtime (plugin `openai-bundled/chrome` 26.917.71314) shows the model:
`tab.ax.get()` / `tab.ax.write()` state and diffs, `tab.dom_cua.get_visible_dom()`,
`tab.playwright.domSnapshot()`, and the related error texts. It is written for a
clean-room reimplementation in cmux. No reference code is reproduced here.

Sources, in order of authority:

1. The renderer itself. `tests/browser-parity/lib/chatgpt-ax-reference.mjs`
   runs the plugin's WebAssembly renderer, read at runtime from
   `~/.codex/plugins/cache/openai-bundled/chrome/latest/scripts/browser-accessibility.wasm.br`,
   on a snapshot built from headless Chrome. Every example below came from it
   unless marked otherwise. Treat it as the golden generator; this document
   explains its output.
2. The service bundle `scripts/browser-service.mjs` (snapshot construction,
   capture timing, dialogs, errors, `get_visible_dom`, `domSnapshot`).
3. Real Codex session logs (format confirmation only).

> Correction to earlier notes: outputs of the form `0 RootWebArea …` /
> `1 none` / `2 generic` / `InlineTextBox` with breadth-first numbering are not
> ChatGPT output. They came from a local reimplementation (`human`
> `cua-repl.ts`). The real renderer prints macOS-style role descriptions
> (`AXWebArea`, `container`, `text`, `text field`), tab indentation, preorder
> IDs, and no ignored or inline-text-box nodes.

## 1. Pipeline

```
CDP (per frame)                          service (JS)                     renderer (WASM, Swift)
Page.getFrameTree ─┐
DOMSnapshot.captureSnapshot ─┼─> snapshot JSON {tab, nodes[], warnings} ──> Revision(prev?, snapshot, mode)
Accessibility.getFullAXTree ─┘                                               .text          (body)
DOM.getFrameOwner (child frames)                                             .identityForElement(id)
                                                                             .isValueSettableForElement(id)
state = `Browser tab: ${id}, Title: ${JSON(title ?? "Unknown")}, URL: ${JSON(url ?? "Unknown")}.\n` + revision.text
```

The service keeps one revision per (session, tab). Each capture passes the
previous revision of that tab, across navigations too, and a mode: `auto` by
default, `full` when `disableDiffing: true`. The renderer rejects a previous
revision only when `tab.id` differs ("Previous accessibility revision belongs
to another document"). Element actions separately check the main-frame
document key `frameId:loaderId`. The renderer decides between full text, diff text and
the no-change message.

### 1.1 Snapshot JSON (renderer input)

```ts
type Snapshot = {
  capturedAt: string;                         // ISO time, not rendered
  tab: { id: number; title: string|null; url: string|null; active: boolean };
  nodes: Node[];                              // parents before children
  warnings: string[];                         // not rendered
};
type Node = {
  parentIndex: number;                        // index into nodes, -1 for the root
  nodeID: string;                             // `${targetId}:${frameId}:${cdpNodeId}`
  role: string|null;                          // CDP role.value, e.g. "button", "StaticText", "RootWebArea"
  chromeRole: number|null;                    // CDP chromeRole.value (ax::mojom::Role enum number)
  name: string|null;
  nameSource: "contents"|"placeholder"|"relatedElement"|"attribute"|"value"|null;
  description: string|null;
  value: string|null;                         // CDP value.value
  properties: Record<PropName, {value: any, relatedNodes: {targetIndex:number,text:string|null,idref:string|null}[]}>;
  dom: {bounds:[x,y,w,h]|null, identifier:string|null, className:string|null,
        declaredRole:string|null, hasAriaDescription:true|null,
        tagName:"input"|"select"|"textarea"|null} | null;
  backendDOMNodeID: number|null;
  targetID: string|null;                      // null for the main target
  dialogTarget?: {dialogID:string, control:"accept"|"dismiss"|"prompt"};
};
```

`tab.id` must be a JSON number; a string id makes the renderer reject the
snapshot ("Invalid accessibility snapshot").

Construction rules (service side):

- Per frame, take `Accessibility.getFullAXTree({frameId})`. Drop every node
  with `ignored: true`; a kept node's parent is its nearest kept ancestor.
  Order is the CDP response order of kept nodes.
- `nameSource` is the type of the first non-superseded `name.sources[]` entry
  that has a value (else the first non-superseded one): `contents`,
  `placeholder`, `relatedElement` pass through; `attribute` maps to
  `placeholder` or `value` when the attribute is `placeholder` / `value`,
  otherwise `attribute`; anything else is null.
- Forwarded properties (others dropped): atomic, autocomplete, busy, checked,
  controls, describedby, details, disabled, editable, errormessage, expanded,
  flowto, focusable, focused, hasPopup, invalid, keyshortcuts, labelledby,
  level, live, modal, multiline, multiselectable, orientation, placeholder,
  pressed, radiogroup, relevant, required, roledescription, selected, settable,
  url, valuemax, valuemin, valuetext. Related nodes map `backendDOMNodeId` to
  the node's index in `nodes` (-1 if absent; dropped if also no text/idref).
- `dom` comes from `DOMSnapshot.captureSnapshot({computedStyles:[],
  includePaintOrder:false, includeDOMRects:false})`: bounds are layout bounds
  minus the document scroll offset; `identifier` = `id` attribute,
  `className` = `class`, `declaredRole` = `role`, `hasAriaDescription` when
  `aria-description` exists; `tagName` only for input/select/textarea.
  A node without a DOM snapshot entry gets `dom: null`.
- Credential redaction. An `<input>` is a credential field when the
  concatenation of its `type autocomplete id name placeholder aria-label title`
  attribute values matches
  `/user[-_ ]?name|e[-_ ]?mail|one[-_ ]?time[-_ ]?code|password|passcode|passwd|\botp\b|\b(?:2fa|mfa)\b|phone|mobile|\btel\b/i`.
  For a credential node, and for any AX node with a backend id but no DOM
  metadata: `value` and `description` become null, `valuetext` is dropped,
  `dom` loses id/class/role/tagName, and `name` becomes null when it came from
  the value or equals the value. Every descendant of such a node is redacted
  the same way and loses its name. (A `MenuListPopup` under a non-credential
  `<select>` is exempt.) Result: `text field (settable) Email` shows no value.
- Closed shadow roots: nodes inside a closed shadow root are removed; text
  that references them is nulled.
- Frames. Child frames are discovered from the frame tree and from
  `IFRAME`/`FRAME` elements without a content document (out-of-process frames,
  attached as separate targets). Frames are processed parents first (stable
  sort by depth). A child frame's nodes are appended after its parent frame's
  nodes; its root (`RootWebArea`) gets `parentIndex` = index of the owner
  element from `DOM.getFrameOwner`. If the owner is not in the kept tree, the
  frame is skipped with a warning. Frame failures are warnings, never text.
  Iframe traversal has a 1000 ms deadline and 500 ms per-call timeout.
- JavaScript dialogs replace the tree (section 5).

## 2. Full state text

```
Browser tab: 1, Title: "ARIA Fixture", URL: "http://host:port/aria.html".
0 AXWebArea ARIA Fixture, URL: host:port/aria.html
	1 heading ARIA roles, Value: 1
		2 text ARIA roles
	3 container Breadcrumb
		4 content list
			5 container
				6 AXListMarker 1. 
				7 link Description: Root, Value: host:port/
	11 container
		15 text field (settable) Labelled by span
		17 text field (settable) Label for, Value: prefilled, ID: for-input
		29 tab (selected, settable, boolean) First, Value: 1
		32 button (collapsed) Menu, Secondary Actions: Expand
		35 slider (settable, integer) Description: Volume, Value: 3

The focused UI element is 0 AXWebArea ARIA Fixture, URL: host:port/aria.html
```

Exact layout of `revision.text` in full form:

- One line per rendered node in preorder: `"\t" * depth + line`, root at
  depth 0. Lines end with `\n`.
- If a focused element exists: an empty line, then
  `The focused UI element is <line>` (same line text, no indentation), with no
  trailing newline. Without a focused element the text ends with the last
  node's `\n`.
- The header line is added by the service, not the renderer. Title and URL are
  JSON-quoted; missing values print `"Unknown"`.

### 2.1 Line grammar

```
<id> <role>[ (<state>, <state>…)][ <title>][<sep><fields>]
fields := field (", " field)*      in this order:
          Description: …, URL: …, Help: …, Value: …, Details: …, Placeholder: …, ID: …, Secondary Actions: …
<sep> is ", " after a title, otherwise " ".
```

- Bare-field rule: when a node has no title and exactly one field, and that
  field is not `Secondary Actions`, the value is printed without its label
  (`container onlyid`, `text field (settable) Required field`,
  `container u.test/`). With a title, or with two or more fields, every
  field is labelled.
- A field equal to the title is omitted (description or value that repeats the
  name).
- Role text is empty for some roles (options, menu items, radiogroup); the line
  is then `16 (selected) Banana` or `55 Item A`.
- `roledescription` replaces the role text (`fancy Nm`).

### 2.2 Title versus Description versus Value

Where the accessible name goes depends on the Chromium role and `nameSource`:

| Condition | Rendered as |
| --- | --- |
| `nameSource` = `attribute` (e.g. `aria-label`, `title`, `alt`) | `Description:` for every role |
| role StaticText, ListMarker, option / MenuListOption, TitleBar | `Value:` (text nodes: `text Hello` via bare rule) |
| chromeRole genericContainer, group(93), link, radioGroup, tabPanel (any source) | `Description:` |
| cell, gridcell, columnheader, rowheader with `contents` source | name dropped (children carry it) |
| `nameSource` = `placeholder` | name dropped; placeholder shows via `Placeholder:` |
| RootWebArea without name | tab title |
| otherwise (`contents`, `relatedElement`, `value`, null) | title |

Other fields:

- `Value:` from `value`; for checkbox/radio/switch/toggle-like roles from
  `checked`/`pressed` (`true`→`1`, `false`→`0`, `mixed`→`2`); for headings the
  level; for tabs selection (`0`/`1`); links use the `url` property
  (shortened, 2.5). A heading shows its level even when it has a value.
- `URL:` from the `url` property on non-link nodes and on the web area (the
  tab URL).
- `Help:` from `description` when it differs from the name.
- `Details:` from `valuetext`.
- `Placeholder:` from the `placeholder` property.
- `ID:` from `dom.identifier`. `className` is not rendered.
- `Secondary Actions: Expand` when `expanded=false`, `Collapse` when
  `expanded=true`. These are the only secondary action names the service
  accepts.

### 2.3 States

Printed in parentheses in this order: `selected` / `selectable`,
`disabled`, `expanded` / `collapsed`, `settable`, then a value type
(`boolean`, `integer`).

- `selected` when `selected=true`; `selectable` when `selected=false` (the
  property exists).
- `disabled` when `disabled=true`.
- `expanded` / `collapsed` from `expanded`.
- `settable` when `settable=true` on text-field-like roles (textbox, combobox,
  searchbox), and for native `<input>` checkbox, radio, range and number
  elements (from `dom.tagName`), for tab (always), and for date/time/color
  inputs. It is not shown on buttons or links.
- `boolean` on tabs, `integer` on native checkbox/radio (and range when the
  value is integral). Not shown elsewhere.
- Not rendered: focusable, focused, required, invalid, readonly, multiline
  (changes role text to `text entry area`), multiselectable, modal, hasPopup
  (changes `button` to `pop up button`), busy, live, atomic, orientation,
  keyshortcuts, autocomplete, relations.

### 2.4 Role text

Keyed on `chromeRole` first, then the CDP role string. Selected mappings
(CDP role → text):

| text | CDP roles |
| --- | --- |
| `AXWebArea` | RootWebArea (every frame's root, including iframes) |
| `container` | generic, none, group, region, main, navigation, banner, contentinfo, complementary, article, paragraph, listitem, dialog, alertdialog, alert, status, log, timer, tooltip, form, search, figure, blockquote, code, emphasis, strong, mark, insertion, deletion, term, definition, note, tabpanel, document, application, math, Iframe, LabelText, Legend, Figcaption, Details, Pre, Section, Header, Footer, LineBreak, LayoutTable*, Abbr, Ruby, Audio, Video, EmbeddedObject, PluginObject, most doc-* and MathML roles, unknown strings |
| `text` | StaticText, InlineTextBox, TitleBar |
| `heading` | heading, doc-subtitle |
| `link` | link, doc-backlink, doc-biblioref, doc-glossref, doc-noteref |
| `button` | button, DisclosureTriangle, PdfActionableHighlight |
| `pop up button` | PopUpButton, ComboBoxSelect, button with hasPopup or chromeRole 137, combobox with chromeRole 209, `<select>` |
| `combo box` | combobox, TextFieldWithComboBox, ComboBoxMenuButton, ComboBoxGrouping |
| `text field` / `text entry area` / `search text field` | textbox / multiline textbox / searchbox |
| `checkbox` | checkbox, ToggleButton, button with `pressed` |
| `radio button`, `switch`, `slider`, `stepper` (spinbutton), `scroll bar`, `splitter` (separator, doc-pagebreak), `toolbar`, `menu bar`, `tab group` (tablist), `tab` | as named |
| `image` | image, SvgRoot, Canvas, graphics-symbol, doc-cover |
| `content list` / `list` / `definition list` | list / listbox, multi-select / DescriptionList |
| `table` / `row` / `cell` / `column` | table, grid, treegrid, ListGrid / row, treeitem / cell, gridcell, columnheader, rowheader / Column |
| `outline` | tree |
| `menu` | MenuListPopup, `role=menu` with items |
| `date field`, `time field`, `color well`, `level indicator` (meter), `progress indicator`, `scroll area` (ScrollView) | as named |
| `AXListMarker` | ListMarker |
| empty | option, MenuListOption, menuitem, menuitemcheckbox, menuitemradio, radiogroup |

The complete measured table (one row per role/chromeRole pair seen in Chrome
153) is reproducible with the reference script; chromeRole numbers are
Chromium enum values and can shift between Chrome versions.

### 2.5 Values and text

- No per-line length limit. Names and values keep embedded newlines verbatim
  (a line can span several physical lines).
- Whitespace-only and empty text nodes are dropped.
- URLs: the scheme `http://` / `https://` and a leading `www.` are removed
  (`x.test/page`, `user:pw@example.test/`, `EXAMPLE.test:443/a`). Other
  schemes stay (`mailto:`, `file:///…`, `about:blank`, `chrome://…`,
  `blob:…`). `data:` URLs and relative URLs are not shown.
- URL budget: the total length of rendered URLs is capped near 4000
  characters. Over budget, URLs are cut to a prefix plus `…` (commonly 120,
  100, 60, 40 or 20 characters) or to `…` alone; which cap wins depends on a
  score whose ties are broken by Swift hash order. Production output is
  therefore not deterministic on URL-heavy pages (the service does not set
  `SWIFT_DETERMINISTIC_HASHING`); the reference script sets it.

### 2.6 Tree shaping

- Ignored CDP nodes never appear (service side).
- A node with no title, no fields, no states and no rendered children is
  omitted (unnamed buttons, generics, separators, empty rows). Exceptions:
  `image` and `tab` render even when empty.
- An unnamed, field-less `container` with exactly one rendered child is
  replaced by that child. Nested unnamed containers are flattened into the
  outer one (children hoisted). A container with an `ID:` or two or more
  children stays. Named containers stay.
- Buttons (and other leaf-like controls) hide all descendants; links, headings
  and containers keep them.
- Consecutive StaticText siblings merge into one `text` line joined by a
  single space (`text Some  bold  and  italic  text with a` when the source
  text had its own spaces). LineBreak ends the run; it is never shown.
  Layout tables (LayoutTable/Row/Cell) collapse into a `container` of text
  lines.
- InlineTextBox is never shown.
- Children limit: a node shows at most its first 500 rendered children and
  appends ` (showing 0-500 of N items)` to its own line. Counted after text
  merging. Viewport bounds do not affect this.
- Depth limit: nodes deeper than depth 200 are dropped silently.
- Warnings, `tab.active`, `capturedAt` and `dom.bounds` do not affect text.

### 2.7 Element IDs

- First revision: IDs are assigned in preorder from 0 (the root).
- Next revisions keep a node's ID when the node matches the previous revision:
  same identity (the backend DOM node id within its target, or the synthetic
  `nodeID` when there is no backend id), same rendered parent, and in the
  longest common subsequence of identities among that parent's children.
  Moving a node to another parent, reordering it among siblings, wrapping it
  in a new container, or having its parent collapsed or uncollapsed gives it a
  new ID. Changes of name, role, state or value keep the ID.
- New IDs are assigned in preorder starting at max(highest ID among kept
  nodes, 0) + 1. IDs are therefore reused after the highest-numbered nodes
  disappear. Example: `a b c z` = 1..4; next revision `a x y` renders
  `1 a, 2 x, 3 y`. When nothing is kept (navigation to a new document, a
  dialog opening or closing) the root becomes `1` and numbering restarts
  from there; only the very first revision of a tab has root `0`.
- Consequence for agents: an old index may now name a different element. The
  service only reports "stale or missing" when the index is absent from the
  current revision.
- IDs are 32-bit; the service rejects indices that are not safe integers.

## 3. Diff and no-change text

`mode: "auto"` compares with the previous revision and emits one of:

1. No change (no added, removed or changed lines):

   ```
   There has been no change in the accessibility tree.
   The focused UI element is 18 text field (settable) Title only
   ```

2. Diff:

   ```
   The following is a diff from the previous accessibility tree with ~ and + representing changed and added elements, respectively. Removed elements are summarized by ID range.
   Removed element IDs: 2
   ~	1 heading Changed heading, Value: 1
   +		74 text Changed heading
   ~		61 button (expanded) More, Secondary Actions: Collapse
   +		75 text Hidden details text
   +		76 button Added
   The focused UI element is 0 AXWebArea ARIA Fixture, URL: host:port/aria.html
   ```

3. Full text (section 2) when the diff would not save enough.

Diff rules:

- Line 1 is the fixed sentence above (with trailing period).
- `Removed element IDs: ` + ascending ranges joined by `, ` (`1-6, 68-71`,
  `3-5, 12`); omitted when nothing was removed. Removed means the previous ID
  is not in the new revision (moved nodes appear as removed + added).
- Then changed (`~`) and added (`+`) nodes in new preorder. The marker is
  followed directly by the node's normal tab indentation and line. Unchanged
  ancestors are not printed.
- "Changed" means the node kept its ID and its rendered line text differs.
  Focus moves alone are not changes.
- The focus line follows directly (no blank line), in both diff and no-change
  forms. There is no trailing newline after it; without focus the text ends
  after the last diff line with `\n`, and the no-change sentence has no
  newline.
- Title-only changes in the header do not count; a changed web-area name
  shows as `~0 AXWebArea …`.

Selection threshold (full vs diff/no-change): use the diff when
`full.length - diff.length >= 1000` bytes and
`(full.length - diff.length) / full.length >= 0.3`. The renderer reads
`TINYSKY_AX_TREE_DIFF_MIN_SAVED_BYTES` (default 1000) and
`TINYSKY_AX_TREE_DIFF_MIN_SAVED_RATIO` (default 0.3) from its environment.
Measured: identical 30-button pages (~900 bytes) repeat the full text; from
~1075 bytes the no-change message appears. `disableDiffing: true` always
returns full text (IDs still continue from the previous revision). After a
navigation the new document shares no backend ids with the old one, so the
result is normally full text with root `1`.

## 4. Modes

- `state` (default): capture, advance the revision, return the text.
  `write()` displays it as tool output; `get()` returns it.
- `screenshot`: returns image bytes only and does not advance the revision.
- `both`: advances the revision and returns `{state, screenshot}`. While a
  JavaScript dialog is open the screenshot is unavailable; the state then
  ends with `\n\nScreenshot unavailable while a JavaScript <type> dialog is open. Use tab.ax.get("state") and tab.ax.click(elementIndex) to interact with its controls.`
  and `screenshot` is absent.

Capture timing (before rendering): wait up to 5 s for a pending navigation to
commit, up to 5 s for first paint after a navigation, then for AX quiet
(no `Accessibility.nodesUpdated`/`loadComplete` for 50 ms after a navigation
or 100 ms otherwise, capped at 750 ms). If a post-navigation capture has fewer
than 100 elements while the DOM has at least max(150, 3x) elements or at least
4000 characters of text, wait 100 ms and retry once. Up to 3 attempts. A
capture needs at least 10 elements and a painted/complete document on the same
host and path to be accepted early. Actions do not need explicit waits.

## 5. JavaScript dialogs

While an alert, confirm or prompt is open, the page tree is replaced by a
synthetic tree (dialog id = CDP dialog id):

```
Browser tab: 1, Title: "Dialogs Fixture", URL: "http://host:port/dialogs.html".
1 AXWebArea Description: Dialogs Fixture, URL: host:port/dialogs.html
	2 container host:port says
		3 text Prompt text
		4 text field (settable) Description: Response, Value: default
		5 button Cancel
		6 button OK

The focused UI element is 4 text field (settable) Description: Response, Value: default
```

- Root: RootWebArea named with the tab title (or `Web page`), source
  `attribute`, so it renders as `Description:`.
- `alertdialog` named `<host> says` (`This page says` when the URL has no
  host), modal.
- StaticText message.
- Prompt only: textbox `Response`, value = current prompt text, focused,
  settable.
- confirm/prompt: button `Cancel`; beforeunload: `Stay`.
- Button `OK` (beforeunload: `Leave`), focused unless a prompt is shown.
- The synthetic nodes have no backend ids and match nothing, so the dialog
  tree is numbered from root `1`. After the dialog closes the page tree
  matches nothing either and is numbered from `1` again.
- beforeunload dialogs are not captured this way.

Dialog interactions: `tab.ax.click(<Cancel/OK id>)`, `setValue(<prompt id>,
text)`, `typeText` (appends to the prompt text), `pressKey` Return/Enter
(accept, or dismiss when the target is Cancel) and Escape (dismiss). Alerts
are always dismissed.

## 6. Errors

AX actions (service): `N` is the element index.

| Condition | Message |
| --- | --- |
| Index not in current revision, or dialog target from an old dialog | `Accessibility element N is stale or missing` |
| Revision is from an older document | `Accessibility element N belongs to a previous page` |
| Capture raced a navigation | `Accessibility capture belongs to a previous page` |
| Empty capture | `Accessibility capture was empty` |
| Capture changed during commit | `Accessibility capture changed before it was committed` |
| Secondary action not `Expand`/`Collapse` or not offered | `Accessibility element N does not support secondary action "<action>"` |
| `setValue` on non-settable element | `Accessibility element N has no settable value` |
| `setValue` on a tab that did not select | `Tab did not become selected` |
| Focus for typing failed | `Could not prepare accessibility element N for input within 250 ms. No input was sent. <cause>` |
| Point outside viewport | `Coordinate is outside the active tab content viewport` |
| Target neither index nor point | `Accessibility action requires an element index or point` |
| Frame of target gone | `Accessibility frame <frameId> is unavailable` / `Click target frame is no longer available` |
| Dialog opened during an action | `Browser action "<kind>" interrupted by JavaScript <type>: <message>. The action may already have taken effect; do not retry it. Inspect or dismiss the dialog before continuing.` (a period is added only if the message lacks final punctuation) |
| Point click on dialog | `JavaScript dialog controls have no viewport coordinates; use an accessibility element index with tab.ax.click(elementIndex)` |
| Non-left click on dialog | `JavaScript dialog controls only support left clicks` |
| Page element targeted during dialog | `A JavaScript dialog is blocking the requested page element` |
| Old dialog control | `JavaScript dialog is no longer active` |
| Other action during dialog | `A JavaScript dialog is active; interact with its controls first` |
| Programmatic activation fallback | `Cannot interact with a detached element`, `Cannot interact with a disabled element`, `Cannot focus a read-only element`, `Accessibility element does not support programmatic activation` |

The "could not prepare" and dialog-blocking errors carry a fresh state: the
thrown message is `<message>\n\n<full state text>` (header included, diffed
against the previous revision like any capture).

Client: `ax capture returned no accessibility state`,
`ax capture returned no screenshot data`. Renderer:
`Invalid accessibility snapshot`,
`Previous accessibility revision belongs to another document`,
`Browser accessibility WebAssembly runtime is not loaded`.

## 7. `tab.dom_cua.get_visible_dom()`

Returns one string: lines joined by `\n`, one per visible interactive element,
in tree order: an element, then its open shadow root, then its light
children.

```
<a node_id=3 href="/">Root</a>
<input node_id=5 aria-label="Frame field" />
<button node_id=6 aria-label="Icon button" />
<input node_id=7 type="checkbox" checked="true" />
```

- Element format: `<tag node_id=ID attr="v" … bool="true">TEXT</tag>`, or
  `<tag node_id=ID … />` when TEXT is empty. `tag` is the lowercase local
  name.
- Attributes, in this order, only when present and non-empty: aria-disabled,
  aria-label, contenteditable, href, name, placeholder, role, title, type,
  value. `value` is omitted for hidden inputs and credential inputs (same
  pattern as 1.1). Then boolean attributes present on the element, rendered
  `="true"`: checked, disabled, multiple, readonly, required, selected.
  Attribute values and TEXT: runs of tab/newline/CR/FF become a space, then
  `&` `<` `>` `"` are escaped as entities.
- TEXT: descendant text nodes (including open shadow roots, skipping
  script/style/noscript/template), each whitespace-collapsed and trimmed,
  joined by spaces, stopping once 160 characters are gathered, collapsed
  again and cut to 160 characters.
- Interactive: tag in a, button, details, input, option, select, summary,
  textarea; or contenteditable not `false`; or has `href` or `onclick`; or
  role in button, checkbox, combobox, link, menuitem, option, radio, slider,
  spinbutton, switch, tab, textbox; or tabindex >= 0. Excluded:
  `aria-hidden="true"`, `hidden`, `input[type=hidden]`, and the agent overlay
  `#codex-agent-overlay-root` subtree.
- Visible: computed visibility `visible`, display not `none`, pointer-events
  not `none`, opacity > 0.01, and some client rect with positive size that
  intersects the visual viewport (clipped to the owning iframe's visible rect
  for child frames).
- Limits: 200 elements and 20000 characters in total (newlines counted);
  output stops at the first element that would exceed either.
- Frames: the main frame first, then visible child frames depth-first in DOM
  order, their elements appended as more lines (no frame marker). Child
  frames share a 1000 ms deadline.
- `node_id`: per tab, a public counter starting at 1 mapped from
  (frameId, loaderId, in-page element ref). The in-page ref is a WeakMap
  counter that survives re-snapshots of the same document, so an element keeps
  its `node_id` across calls. The map resets on a new main-frame document or
  after 5000 entries. Unknown ids fail with `DOM node <id> is stale or missing`.

## 8. `tab.playwright.domSnapshot()`

Playwright's AI ARIA snapshot (`incrementalAriaSnapshot(body, {mode: "ai"})`,
the format of `page._snapshotForAI()`), with iframes expanded and then
simplified:

1. Take the snapshot of `document.body` (or `documentElement`).
2. For each `- iframe … [ref=R]` line whose element is visible and not
   `aria-hidden`: insert `[id="…"]` and/or `[name="…"]` (JSON-quoted values)
   before `[ref=R]`, snapshot the iframe body the same way (recursively,
   500 ms per frame), append `:` to the iframe line if missing, and insert the
   child lines indented by the iframe line's indentation plus two spaces.
3. If the result has list lines, rebuild it as a tree by indentation and:
   remove ` [ref=…]` and ` [cursor=…]` from every line; delete
   `- img…` nodes together with their children; replace lines matching
   `- generic`, `- listitem` or `- group` with only bracket attributes and an
   optional trailing `:` by their children (inline-text forms like
   `- generic: Email` stay); drop blank lines; re-indent with two spaces per
   level.

```
- heading "Sign in" [level=2]
- paragraph:
  - text: Don't have an account?
  - link "Sign up":
    - /url: /signup
- tablist:
  - tab "Email" [selected]
  - tab "Phone"
- generic: Email
- textbox "Email"
- iframe [id="payment"]:
  - button "Pay"
```

## 9. Reference generator

```
node tests/browser-parity/lib/chatgpt-ax-reference.mjs /aria.html
node tests/browser-parity/lib/chatgpt-ax-reference.mjs /aria.html --then "<js>" --click "<css>"
node tests/browser-parity/lib/chatgpt-ax-reference.mjs <url> --full | --json
```

Paths starting with `/` are served from `tests/browser-parity/fixtures` on two
loopback origins (`peer` query parameter set for cross-origin frames). Each
`--then`/`--click` step captures again in auto mode, so the output shows diffs
and no-change messages. `--json` prints the renderer input. It uses headless
Chrome (`channel: "chrome"`) with a fresh profile and the Playwright bundled
in `/Applications/ChatGPT.app`, never the user's profile. Module API:
`loadChatGPTAccessibilityCore()`, `new ChatGPTAxReference(page, core)`,
`.state({disableDiffing})`, `.dialogState(dialog)`, `.snapshot()`,
`javaScriptDialogNodes()`.

Differences from the live service: tab ids are small integers, title comes
from `Target.getTargetInfo`, capture timing (section 4) is replaced by a fixed
settle delay, deterministic hashing is on, and out-of-process frames are
reached through Playwright CDP sessions. Like the service, it always diffs
against the tab's previous revision, across navigations.

## 10. Open questions

- The exact tier and score of the URL budget (2.5); it is hash-order
  dependent in production, so cmux should pick a deterministic rule.
- Unobserved renderer strings: `Scroll to Visible`, `Selected text:` followed by a fenced block,
  the "Pay special attention to the content selected by the user" note, and
  `Remove unused rows/columns` for tables. The service never sends selection
  data, so these are likely unused in browser mode.
- A focused node that is pruned still gets a focus line with a fresh ID that
  is not in the tree (`The focused UI element is 2 container`); a focused node
  under a leaf control gives no focus line. Whether cmux should copy this.
- The ID-matching model in 2.7 fits every probe (moves, reorders, wraps,
  collapses, new backend ids), but was inferred, not read from source.
