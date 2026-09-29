# Aside `snapshot()` behavioral spec

> Reference study, kept for the record. cmux does not implement this format; the goldens it cites were removed with the dialects and remain in git history.

Clean-room behavioral description of the text tree that Aside's REPL `snapshot(page, options)` returns, written so cmux can reproduce it byte for byte. It describes rules and algorithms, not Aside's source.

Evidence: the per-frame page script (`globalThis.__aside`, Aside daemon 1.0.928.1), the host-side frame stitching and header code in the same daemon, the goldens in `tests/browser-parity/goldens/aside/`, and live `aside repl` probes against local pages (2026-09-28). A statement marked **(observed)** was confirmed live. A statement marked **(bug)** is Aside behavior that looks unintended. Reproduce it only when strict parity matters, and keep the decision explicit in cmux code.

## 1. API surface

```
snapshot(page, {
  interactive?: boolean,   // default false
  showHidden?: boolean,    // default false
  ref?: string,            // "e12" or "f1e2": scope to that element
  selector?: string,       // CSS selector: scope to the first match in the main frame
  maxDepth?: number,       // default 50
  maxChars?: number,       // default none
}) -> { tree: string, refs: Record<ref, RefMeta>, diff: string }
```

The REPL guide lists only `{tree, diff}`, but `refs` is also returned **(observed)**. Options that are `undefined` are removed when the options go to the page (JSON transport), so the page defaults apply: `maxDepth` 50, `interactive` false, `showHidden` false.

Snapshots of one page run one at a time (a per-page promise queue).

## 2. Output assembly (host)

`tree` is the following list of lines, with empty entries removed, joined by `\n`:

1. `# note: interactive (clickable / focusable) elements only.` when `interactive` is set.
2. `# note: hidden elements are shown.` when `showHidden` is set.
3. `- title: "<title>" [url=<url>]`.
4. The stitched frame tree (section 9). It is omitted when empty.

`<title>` is the CDP page title (empty string on failure). It is **not escaped** **(bug)**: `- title: "Q "quoted" title" [url=...]` **(observed)**.

`<url>` is `truncateUrl(page.url())`:

- Parse the URL. On failure, return it unchanged, or its first 128 characters plus `…` when it is longer than 128.
- Iterate the query keys in order. Delete each key whose lowercase form is one of `utm_source utm_medium utm_campaign utm_term utm_content gclid gclsrc fbclid mc_cid mc_eid msclkid twclid li_fat_id _ga _gl _t _ts _nc`. The deletion happens while the key iterator is live, so the key right after a deleted key is skipped and survives **(bug)**: `?utm_source=a&utm_medium=b&x=1` becomes `?utm_medium=b&x=1`. A deletion re-serializes the query in form-urlencoded style (`%20` becomes `+`). A URL with no deletion keeps its original query encoding.
- Serialize with WHATWG `URL.toString()`, which lowercases the host, drops a default port, and adds `/` to an empty path.
- If the result is longer than 128 characters, return its first 128 characters plus `…`.

`diff` is described in section 11. `refs` is the union of the ref maps from all frames that were snapshotted (section 10).

`selector` preflight: before the snapshot, the host runs `document.querySelector(selector)` in the main frame. If nothing matches, it throws `Selector "<sel>" matched no elements on page.` **(observed)**.

## 3. Line grammar

```
line      := indent "- " body
indent    := "  " * depth
body      := node | node ":" | node ": " quoted | "text: " quoted | option
node      := role [" " quoted] attrs
attrs     := [" [ref=" REF "]"] [" [level=" N "]"] [" [hidden]"] [" [scrollable]"]
             [" [checked]"] [" [disabled]"] [" [focused]"] [" [selected]"]
             [" [placeholder=" quoted "]"] [" [size=" W "x" H "]"]
option    := "option" [" " quoted] [" (selected)"] [" value=" quoted]
quoted    := '"' escape(text) '"'
escape(s) := s with `"` -> `\"` and LF -> `\n`
```

The attribute order above is fixed. `[ref=]` comes before `[level=]`. `escape` does not escape backslash, CR, or TAB, so the output can be ambiguous **(bug)**.

The grammar has no `[expanded]`, `[pressed]`, `aria-current`, `aria-describedby`, value text for progress or slider, `href`, or input `type`. Aside computes some of these values internally and never prints them. Examples: `button "Menu" [ref=e13]` has `aria-expanded="false"`, and `button "Bold" [ref=e14]` has `aria-pressed="true"` (golden 02-aria).

## 4. Roles

`role(el)`:

1. Explicit role: split the `role` attribute on spaces, lowercase each token, and use the first token that is in the WAI-ARIA role list (alert, alertdialog, application, article, banner, blockquote, button, caption, cell, checkbox, code, columnheader, combobox, complementary, contentinfo, definition, deletion, dialog, directory, document, emphasis, feed, figure, form, generic, grid, gridcell, group, heading, img, insertion, link, list, listbox, listitem, log, main, mark, marquee, math, meter, menu, menubar, menuitem, menuitemcheckbox, menuitemradio, navigation, none, note, option, paragraph, presentation, progressbar, radio, radiogroup, region, row, rowgroup, rowheader, scrollbar, search, searchbox, separator, slider, spinbutton, status, strong, subscript, superscript, switch, tab, table, tablist, tabpanel, term, textbox, time, timer, toolbar, tooltip, tree, treegrid, treeitem). `presentation` and `none` fall through to the implicit role. An explicit role prints verbatim, so `role="img"` prints `img` but `<img>` prints `image`.
2. Implicit role:
   - contenteditable (`contentEditable` is `true` or `plaintext-only`) gives `textbox`. This check comes before the tag checks.
   - `input`: `submit` and `button` give `button`. `file` gives `button`. `checkbox` gives `checkbox`. `radio` gives `radio`. Every other type gives `textbox`, including `range`, `number`, `image`, and `reset` **(bug for image and reset)**.
   - Tag map: `a` link, `button` button, `iframe` iframe, `select` combobox, `textarea` textbox, `h1`–`h6` heading, `canvas` canvas, `svg` image, `img` image, `nav` navigation, `main` main, `header` banner, `footer` contentinfo, `section` region, `article` article, `aside` complementary, `form` form, `table` table, `ul` and `ol` list, `li` listitem, `p` paragraph, `label` label.
   - Every other tag gives `generic`. This includes `div`, `span`, `option`, `tr`, `td`, `th`, `fieldset`, `legend`, `figure`, `details`, `summary`, `pre`, `em`, `strong`, and `dialog` without a role.

`header`, `footer`, `section`, and `form` map without landmark-context rules. An unnamed `section` is `region` **(observed)**.

## 5. Accessible name

`name(el)` for the node label. The result is later normalized (collapse whitespace, trim, first 100 characters).

If `role(el)` is one of caption, code, definition, deletion, emphasis, generic, insertion, mark, paragraph, presentation, strong, subscript, superscript, term, time, the name is `""`. `aria-label` on a `div` or `span` is therefore ignored **(bug)**.

Otherwise run `compute(el, ctx)`, collapse whitespace, trim, and cut to 300 characters. `ctx` holds `inLabelledBy`, `inLabel`, `depth` (limit 10), and a visited set. Each branch copies the visited set, so a cycle only stops on its own path. Steps, first non-empty result wins:

1. Stop with `""` when the depth is 10 or more, or `el` is already visited.
2. If not `inLabelledBy` and not `inLabel`: return `""` when `el` has `aria-hidden="true"`, or its own computed style is `display:none` or `visibility:hidden`. Only the element's own style counts, not its ancestors.
3. If not `inLabelledBy`: for each IDREF in `aria-labelledby` (resolved with `ownerDocument.getElementById`), compute with `inLabelledBy`. Join with spaces and collapse whitespace.
4. The trimmed `aria-label`.
5. For `input`, `textarea`, `select`, `meter`, `progress`, and `output`, when not in a label context: the labels are every `label[for=<id>]` in the owner document plus the nearest ancestor `label`. Compute each with `inLabel`, then join with spaces. The control itself is on the visited path, so it contributes nothing to its own label text **(observed: `textbox "Email"`, not `Email you@x.com`)**.
6. `alt` (trimmed, even when empty, which stops the search) for `img`, `area`, and `input[type=image]`.
7. `fieldset` legend, `figure` figcaption, and `table` caption: compute the child element. In practice these branches give nothing. `fieldset` and `figure` are `generic`, so their names are prohibited. `caption` is `generic`, so it contributes nothing outside a label context **(bug)**: `table: "Scores Name Score Ada 9"` **(observed)**.
8. `select`: the trimmed `textContent` of the selected option.
9. If the role is one of button, link, heading, cell, columnheader, rowheader, tooltip, tab, menuitem, menuitemcheckbox, menuitemradio, treeitem, option, listitem, row, term, or `ctx` is a label context: the concatenation, with no separator, of `::before` content, the raw text of each child text node, `compute(child)` for each child element, and `::after` content. Collapse whitespace and trim. A child element whose role is not in this list and that is not in a label context contributes nothing (except its alt, title, and similar attributes). This means `<li>first <b>bold</b></li>` is named `first` **(observed, bug)**. Children are light-DOM `childNodes` only.
10. `input[type=submit|button]`: the trimmed `.value`.
11. The trimmed `placeholder`.
12. The trimmed `title`.

CSS content: take the computed `content` of the pseudo-element. Return `""` when the element's pseudo style is `display:none` or `visibility:hidden`, or `content` is `none` or `normal`. Otherwise concatenate only the quoted string literals and unescape `\n \r \t \f \" \' \\`. `attr()` and counters are dropped.

## 6. Traversal

The walk is a pre-order DOM walk that builds an intermediate tree. Its root is a `fragment` node, which is not printed.

Start point: the `ref` element (from this frame's registry), or the first `selector` match (with a fallback that is effectively dead, see section 12), or `document.body`.

Child order for each element: the `::before` string, then `childNodes`, then `shadowRoot.childNodes` (open shadow roots only), then `aria-owns` targets (IDREFs resolved in the owner document, excluding itself and duplicates), then the `::after` string. Slotted light children therefore appear before the shadow content, and `<slot>` is not followed. A visited set prevents a second visit, so an `aria-owns` target shows under its owner when the owner is walked first **(observed)**.

`traverse(el, depth, parent)`:

```
if depth > maxDepth or el is visited: return
mark visited
traversable = shouldTraverse(el)
isRoot      = (no ref option) and el == document.body
include     = isRoot or (traversable and (shouldInclude(el) or (showHidden and !isVisible(el))))
if !traversable and !isRoot: return
target = parent
if include:
    node = toNode(el)            // may be null, see below
    if node: parent.children.push(node); target = node
if !include and interactive and el.childNodes is empty:
    n = normalizeName(name(el)); if n and target is not the fragment: target.children.push(n)
if depth < maxDepth:
    push ::before string to target (if any)
    next = (include and node) ? depth + 1 : depth
    for child in childNodes + shadow childNodes:
        text node: if nodeValue is non-empty and target.role != "textbox": target.children.push(nodeValue)  // raw, not trimmed
        element:   traverse(child, next, target)
    for owned in aria-owns: traverse(owned, next, target)
    push ::after string to target (if any)
```

Depth counts only nodes that were emitted. An element whose node is null does not increase the depth.

`shouldTraverse(el)`:
- `false` for `script`, `style`, `meta`, `link`, `title`, `noscript`.
- `false` for `aria-hidden="true"` when the element has no element children, even with `showHidden` **(bug)**.
- When `!showHidden` and `!isVisible(el)`: `false`. The exception is `input[type=radio|checkbox]`, which is still walked. It shows with `[hidden]`, so visually hidden custom checkboxes appear without `showHidden`.
- Otherwise `true`.

`shouldInclude(el)`:
- interactive mode: role is `canvas`, or `isInteractive`, or `isScrollable`, or `isLandmark`.
- default mode: `isInteractive`, or `isScrollable`, or `isLandmark`, or `name(el)` is non-empty, or the role is not `generic` and not `image`. An `image` with a name is included **(observed: `image "Logo"`)**.

`isLandmark(el)`: the tag is one of h1–h6, nav, main, header, footer, section, article, aside, **or** the element has any valid explicit role other than presentation or none. Explicit `tablist`, `tabpanel`, `alert`, `dialog`, `tree`, and `group` therefore survive interactive mode **(observed)**.

`isInteractive(el)`: any of these is true:
- the tag is `a`, `button`, `input`, `select`, `textarea`, `details`, or `summary` (an `<a>` without `href` counts);
- the element has an `onclick` attribute;
- the element has a `tabindex` attribute whose value is not `"-1"`;
- the explicit role is `button` or `link`;
- the `contenteditable` attribute is exactly `"true"`;
- the computed `cursor` is `pointer`, unless the direct parent is also `pointer` and the element has no `onclick` and no qualifying `tabindex`.

`isScrollable(el)`: never true for `html` or `body`. Otherwise `overflow-x` or `overflow-y` is `auto`, `scroll`, or `overlay`, and `scrollHeight > clientHeight + 1` or `scrollWidth > clientWidth + 1`.

`isVisible(el)` is cached per snapshot:
1. `false` when the element has `aria-hidden="true"`. Only its own attribute counts. An `aria-hidden` ancestor does not hide a descendant for this test.
2. Walk from `el` up to, but excluding, `<html>`, and cross shadow roots to their host. At each step: a `display:contents` step is skipped and remembered. `display:none` gives `false`. `overflow` (any axis) `hidden` or `clip` with `offsetWidth` or `offsetHeight` equal to 0 gives `false`. An `IFRAME` with a zero size gives `false`. `visibility:hidden` at that step gives `false`, unless `el` itself computes `visibility:visible`. `opacity` equal to 0 gives `false`.
3. If `checkVisibility({checkOpacity, checkVisibilityCSS})` is false and there is no `display:contents` ancestor: `false`.
4. For an HTMLElement whose rect has a positive size and `right <= 0` or `bottom <= 0`: `false` when its own `overflow-x` and `overflow-y` are both not `visible`. An element at `left:-9999px` therefore stays visible **(observed: `text: "Offscreen text"`)**.

Options inside a closed `<select>` fail this test, so they are not walked in default mode. The select renders its options separately (section 8).

`toNode(el)` returns null or a node with these fields:
- `role`; `name = normalizeName(name(el))`; `hidden = !isVisible(el)`; `scrollable`.
- `ref`: assigned (section 10) when the role is `iframe` or `canvas`, or the element is scrollable, or `isInteractive`, or the role is one of button, link, textbox, checkbox, radio, combobox, listbox, menuitem, menuitemcheckbox, menuitemradio, option, searchbox, slider, spinbutton, switch, tab, treeitem, or the role is one of cell, gridcell, columnheader, rowheader, listitem, article, region, main, navigation **and** the name is non-empty. An unnamed `main` or `nav` gets no ref **(observed: `- main:`)**.
- Return null when the role is `generic`, there is no ref, and the element is visible. Unreffed visible wrappers dissolve, and their text and children move up to the nearest emitted ancestor.
- `level`: only for heading, listitem, row, treeitem. A heading with a native `h1`–`h6` tag uses that tag number, and `aria-level` is ignored. Otherwise use `aria-level` when it is an integer ≥ 1. `<h2 aria-level="5">` prints `[level=2]` **(observed)**.
- `checked`: for a native checkbox or radio `input`, its `.checked`. Otherwise `aria-checked="true"` (case-insensitive) on checkbox, radio, menuitemcheckbox, menuitemradio, or switch. `mixed` is not printed.
- `selected`: for an `<option>` element, its `.selected`. Otherwise `aria-selected="true"` on gridcell, option, row, tab, rowheader, columnheader, or treeitem.
- `disabled`: only when the role is in the disabled-capable set (application, button, composite, gridcell, group, input, link, menuitem, scrollbar, separator, tab, checkbox, columnheader, combobox, grid, listbox, menu, menubar, menuitemcheckbox, menuitemradio, option, radio, radiogroup, row, rowheader, searchbox, select, slider, spinbutton, switch, tablist, textbox, toolbar, tree, treegrid, treeitem). The value is true when the element is a `button`, `input`, `select`, `textarea`, `option`, or `optgroup` that matches `:disabled` (a disabled fieldset counts), or when the element or any ancestor, crossing shadow roots, has `aria-disabled="true"`.
- `focused`: `ownerDocument.activeElement === el`. Focus inside a shadow root marks the host, not the inner control. Focus inside a child frame marks the `<iframe>` element in the parent **(observed: `iframe "Cross origin" [ref=e2] [focused]`)**.
- `placeholder`: the raw `placeholder` attribute of any element. It prints even when the name also came from it.
- `size`: canvas only, `round(width)x round(height)` of the bounding rect.
- The initial children hold one string, the textbox value, when that value is not null:
  - contenteditable: `innerText`.
  - `input` of type checkbox, radio, or file: null.
  - `input[type=password]`: `[redacted]` when non-empty, else `""`.
  - other `input` and `textarea`: `.value`.
  - any other element: null.

  Direct text-node children of a textbox are skipped by the walk. Element children of a contenteditable are still walked.

## 7. Normalization passes

These passes run in order on the fragment after the walk.

`mergeStrings(parts)`: for each non-empty part, append it. Before appending, insert one space when the accumulated text (trimmed at its end) ends with a Unicode letter or digit and the part (trimmed at its start) starts with one. Existing whitespace does not stop the insertion. Trim the result at both ends only, so interior whitespace, including newlines, stays. Consequences **(observed)**:
- `Plain <strong>bold</strong> text.` gives `Plain  bold  text.` (two spaces).
- `, and<b>X</b>Y` gives `, and X Y` (spaces that the page does not render) **(bug)**.
- `::before{content:"BEFORE "}` plus `x` gives `BEFORE  x`.

**Pass A: string children** (post-order):
- Each run of adjacent string children becomes one `mergeStrings` result. An empty result is dropped.
- A child `paragraph` that is a bare wrapper (no name, level, hidden, scrollable, checked, selected, focused, disabled, ref, hints, href, type, placeholder, or size) and has only string children dissolves into the surrounding string run as `mergeStrings(its children)`. A `<p>` that holds only text therefore prints as `- text:`, not `- paragraph:` **(observed: `text: "none"`, `text: "Dialog body"`)**. A paragraph with an element child stays a paragraph.
- When the node has exactly one child and that child string equals the node name exactly, remove it.

**Pass B: wrappers** (post-order, returns a replacement list for each node):
- If the node is hidden, has no ref, and has no ref in its normalized subtree: remove it with its subtree. `showHidden` therefore reveals only hidden elements that carry refs or contain refs. Hidden paragraphs and text vanish **(observed: the showHidden golden equals the default output)**.
- A bare paragraph whose only child is a paragraph is replaced by that child.
- A `generic` that is visible, has no name, and whose children are all ref'd element nodes, with 0 or 1 children, is replaced by those children. The generic's own ref is **not** checked, so the ref is assigned (it is in `refs`) but its line disappears **(bug)**. Effects: the ref numbers skip (`generic "More" [ref=e22]` after the `<details>` wrapper took e21), and a clickable `<div onclick>` with only an icon or no content disappears **(observed)**. Adjacent strings that meet after this flattening are not merged again.

**Pass C: leaf-text merge** (post-order). This pass applies to a node that is visible, has a ref, and has 1–3 children, where every child is a non-empty string (trimmed) or a visible leaf node with role generic, heading, paragraph, or label that has a name and no children:
- `merged = normalizeName(texts.join(" "))`.
- When the node has no name: `name = merged`, and the children are removed. Examples: `generic "one two" [ref=e4]`, and `button "A B C D"` for `<div role=button><span>A</span>…` **(observed)**. The value of an unnamed textbox becomes its name: `<input value="foo">` gives `textbox "foo" [ref=e1]` **(observed, bug)**.
- When the node has a name and the name equals `merged` with all whitespace removed: remove the children. A textbox whose value equals its name therefore hides the value: `<input aria-label="hi" value="hi">` gives `textbox "hi" [ref=e2]` **(observed, bug)**.

`normalizeName(s)` = collapse whitespace runs to one space, trim, first 100 characters.

**Duplicate check**: if any ref occurs twice in the tree, the frame returns the error `Snapshot produced duplicate refs: <sorted list>. Take a new snapshot and retry.`

## 8. Rendering

Render the fragment's children at depth 0. For each node at depth `d`:

- When the node has exactly one child, the child is a string, and the node is not a `<select>`: print `- <node>: "<trimmed text>"`, or `- <node>` when the trimmed text is empty. Example: `textbox "Bio" [ref=e7]: "hi"`, `listitem "first" [ref=e11]: "first  bold"`.
- Otherwise print `- <node>`, with a trailing `:` when the node has any children or is a `<select>`.
- For a `<select>`, the next lines at `d+1` are one line for each entry of `select.options` (optgroup children included, disabled options unmarked):
  - `- option`
  - plus ` "<text>"` when the trimmed `textContent` is non-empty. The text has whitespace collapsed and is cut to 100 characters.
  - plus ` (selected)` when the option is selected.
  - plus ` value="<value>"` when `.value` is non-empty and differs from the trimmed (uncollapsed) text. Example: `- option "Why" (selected) value="y"` **(observed)**.
- Then each child at `d+1`: a string prints as `- text: "<trimmed>"` (skipped when empty), and an element node renders recursively.

Indentation is two spaces for each level. Lines are joined with `\n`, and there is no trailing newline.

If `maxChars` is set and the frame's text is longer than `maxChars`, the frame returns an error:
- `Output exceeds <maxChars> character limit (<len> characters). ` followed by
- (with ref) `The specified element has too much content. Try a smaller maxDepth or focus on a more specific child element.`
- otherwise `Try an even smaller maxDepth, or 'ref' to focus on a specific element from the page.`

The third message variant is unreachable because `maxDepth` always defaults to 50 **(observed)**. The limit applies to each frame's text before stitching and before the header, so the final `tree` can be longer than `maxChars`.

## 9. Frames

Frame prefixes: take the frames the page's frame manager knows, in BFS order from the main frame. Siblings come in the order the manager first registered them, not in DOM order. The main frame has the prefix `""`, and the other frames get `f1`, `f2`, …. The numbers are assigned again at every snapshot and stored as the prefix map that locators use. Consequences **(observed)**:
- A cross-origin iframe that appears later in the DOM got `f1`, and the same-origin iframe got `f2`.
- After a reload, detached frames that the manager still held inflated the numbers (`f2`, `f4`).

Snapshot root frame: the main frame, or with `ref` the frame whose prefix matches the ref. When no frame matches: `Ref "<ref>" points to a frame that is no longer available. Take a new snapshot.`. Snapshot every frame in the root's subtree in parallel, with `refPrefix` set to its prefix. `ref` and `selector` apply only in the root frame, so each descendant frame is snapshotted in full. The root frame retries its injection up to 3 times, 300 ms apart. A descendant that fails or returns an error is left out silently. A root failure throws that error.

Stitching, in the host:
1. For each snapshotted frame, map every ref'd `<iframe>` in its refs to its child frame id (CDP `DOM.describeNode`).
2. Password-manager iframes: when the child frame URL or `src` starts with a known extension origin (1Password, Bitwarden, Dashlane, LastPass, Aside Vault), rewrite that iframe's line from `- iframe` to `- iframe [origin="<label>"]`. The origin label comes before the name.
3. Process the non-root frames deepest first. When the parent tree has a line matching `^(\s*)- iframe(.*? )?\[ref=<iframeRef>\]`, append `:` to that line (only when the child text is non-empty) and insert the child lines under it, each indented by the iframe line's indent plus two spaces. Otherwise (**orphan**) append this to the end of the parent text:
   ```
   - iframe[ [origin="…"]]:
     <child lines indented by two spaces>
   ```
   The orphan has no name and no ref.
4. The result is the root frame's text.

Orphans are common **(observed)**:
- interactive mode: `<iframe>` is not interactive or a landmark, so it gets no node and no ref. Every frame is appended as a nameless orphan at the end of its parent, and nested frames are nested orphans.
- `selector` or `ref` scope: every descendant frame of the root frame is appended as an orphan even when the iframe is outside the scope **(bug)**. Example: `snapshot(page, {selector: "#L"})` printed the list, then `- iframe:` with the whole frame.

Frame refs have the form `<prefix>e<n>`, for example `f1e2`. Each frame document has its own counter.

## 10. Refs: numbering, persistence, map, and resolution

Each frame document's isolated world has one counter that starts at 0 and **never resets** while the document lives. Each ref'd element holds a private cache `{role, name, ref}`. During node creation:

- If the cache exists, and its role equals the current role, its name equals the current normalized name, and its prefix equals the current frame prefix: reuse the cached ref.
- Otherwise assign `<prefix>e<++counter>` and overwrite the cache.

Numbers therefore follow first-seen pre-order walk order, and later snapshots keep the old numbers for elements whose role and name do not change. An element whose name changes gets a new, higher number. Inserted elements get new numbers. Examples **(observed)**: a list item `Beta` → `Beta2` went from `e8` to `e19`; an inserted `Zero` got `e18`; `Alpha` and `Gamma` kept `e7` and `e9`. A clicked frame button that became `Inner clicked …` went from `f2e1` to `f2e3`. A new document (navigation or reload) starts again at `e1`. A frame whose prefix changes gives new numbers to all its elements. Elements that are not emitted (for example list items in interactive mode) use no numbers, so an interactive snapshot taken first and a full snapshot taken later number differently from the reverse order.

Registry: at the start of each non-capture snapshot, the frame clears its ref→element registry. With `ref`, it keeps only that root. It then registers every ref assigned in this snapshot, including refs whose lines Pass B dropped. **A scoped snapshot therefore makes stale every ref outside its scope** **(observed: `page.locator("e10")` failed after `snapshot(page, {selector: "#L"})`)**. This matches the guide text "each new snapshot invalidates all earlier ref IDs", but refs that are assigned again keep their old strings.

`refs` map entry for each ref: `{ role, name: name(el) first 100 characters (not whitespace-normalized again), tagName (uppercase), inputType: el.type or omitted, ariaLabel or omitted, placeholder or omitted, nthAmongSameSignature }`. `nth` counts earlier refs in the same snapshot with the same `role::name` signature, in assignment order. Dropped refs (Pass B) are included.

Locator resolution for `page.locator("e12" | "f1e2" | "[ref=e12]")`:
- A string that matches `^(f\d+)?e\d+$` (or `[ref=…]`) is a ref. `frame.locator(ref)` throws `Snapshot refs already include frame identity; use page.locator(ref) instead of frame.locator(ref).`
- Map the prefix to a frame through the last snapshot's prefix map. With no map, `""` means the main frame. An unknown prefix gives the error `Ref "<ref>" is stale — the element was removed or the page changed. Take a new snapshot and retry.`
- In that frame, `deref(ref)`: return the registry element when it is still connected. Otherwise take the meta for the ref from the frame's latest snapshot and walk `document.body` elements (light DOM only, at most 5000). Collect the elements whose role equals the meta role and whose `name()` (up to 300 characters) equals the meta name (up to 100 characters). Names longer than 100 characters never match **(bug)**. Return the only candidate, or the candidate at index `nthAmongSameSignature` when it exists, else null. This rebinds a ref after a re-render of an element with the same role and name.
- A null result is stale. Frame refs retry 3 times (backoff 50·i ms). Main-frame refs try once.

## 11. `diff`

State: every tab stores the raw stitched text of its last `snapshot()` (without the header). The first snapshot compares against `""`. The comparison ignores options and URL, so a scoped or interactive snapshot is compared against whatever snapshot came before it. Reloads do not reset the state.

```
old = previous.trim().split("\n");  new = current.trim().split("\n")
ops = myers(old, new)                          // equal / delete / insert, in order
hunks = zero-context grouping of ops
diffText = hunks.length == 0 ? "No changes detected\n"
         : hunks.map(h => [header(h), ...h.lines].join("\n")).join("\n") + "\n"
result.diff = diffText.length > result.tree.length ? result.tree : diffText
```

`"".split("\n")` is `[""]`. The first snapshot's diff is therefore `@@ -1 +1,N @@\n-\n+…` (one empty line deleted), or the full `tree` with its header when that is shorter **(observed both)**.

Myers (reproduce the tie-breaks exactly, because they fix the order of `-` and `+` lines inside a hunk):

```
N=len(a), M=len(b), MAX=N+M; if MAX==0 return []
if N==M and all a[i]==b[i]: return all equal
V = int[2*MAX+1] filled with -1, offset=MAX, V[offset+1]=0, trace=[]
for d in 0..MAX:
  trace.push(copy(V))
  for k in -d..d step 2:
    down = (k == -d) or (k != d and V[k-1] < V[k+1])
    x = down ? V[k+1] : V[k-1] + 1
    y = x - k
    while x<N and y<M and a[x]==b[y]: x++, y++
    V[k] = x
    if x>=N and y>=M: return backtrack(trace)
backtrack: x=N, y=M, out=[]
  for d from len(trace)-1 down to 1:
    V = trace[d]; k = x - y
    pk = (k == -d or (k != d and V[k-1] < V[k+1])) ? k+1 : k-1
    px = V[pk]; py = px - pk
    while x>px and y>py: x--, y--, out.push(equal a[x])
    if x == px: y--, out.push(insert b[y])
    else:       x--, out.push(delete a[x])
  while x>0 and y>0: x--, y--, out.push(equal a[x])
  return reverse(out)
```

Hunks: counters `o=1`, `n=1`. An equal op closes the open hunk, then `o++` and `n++`. A delete or insert opens a hunk when none is open (`oldStart=o`, `newStart=n`, counts 0). A delete appends `-line` and does `oldCount++, o++`. An insert appends `+line` and does `newCount++, n++`. There are **no context lines**.

Header: `@@ -R +R @@`, where `R` is `start` when `count == 1`, else `start,count`. A zero count prints `start,0`, and `start` is the next line number. It is not decremented as in GNU diff. Example: `@@ -19,0 +19 @@` for a line appended after 18 old lines **(golden 03)**, and `@@ -1,6 +1,0 @@` **(observed)**.

Golden 03 example (interactive, after fill, check, select, and submit):
```
@@ -7,2 +7,2 @@
-  - textbox "Email" [ref=e4] [placeholder="you@x.com"]
-  - checkbox "Accept terms" [ref=e5]
+  - textbox "Email" [ref=e4] [placeholder="you@x.com"]: "me@x.com"
+  - checkbox "Accept terms" [ref=e5] [checked]
@@ -12,2 +12,2 @@
…
@@ -19,0 +19 @@
+- text: "Submitted me@x.com tos=true plan=Team"
```

## 12. Scoping details

- `selector`: the page uses `document.querySelector(sel)`. It then falls back to a scan when `sel` has the exact form `[role="x"]` or `[role='x']`, where the scan finds the first element whose computed role (implicit or explicit) is `x`. The host preflight (section 2) already threw for non-matching selectors, so this fallback is unreachable from `snapshot()` **(bug)**. The matched element is the walk root. It is not `body`, so it prints as a normal node (`- form:` at depth 0). A hidden match gives an empty tree.
- `ref`: the walk root is the registry element. When it is missing or disconnected: `Element with ref '<ref>' not found. It may have been removed from the page. Take a snapshot without 'ref' to get the current page state.` **(observed)**. When `ref` is a frame ref, the main frame is not snapshotted at all.
- In interactive mode the walk still descends through non-included elements. It flattens their included descendants into the nearest included ancestor and moves their text there. An empty leaf element (no childNodes) that is not included gives its name as text (for example an `<img alt="Logo">` adds `Logo`). Adjacent text from many wrappers merges into one line through `mergeStrings`: `- text: "One Two\n Plain  bold  text. Logo"` **(golden 01)**.
- `maxDepth`: see section 6. Elements at depth `maxDepth` are emitted but their contents (text and children) are not walked. Names come from the DOM, so they stay complete. Ref'd unnamed generics then lose their children and Pass B drops them **(observed: the scrollable div and the `tabindex` div vanished at `maxDepth: 1`)**.

## 13. Worked examples (verified)

Form fixture (`fixtures/index.html`), default mode:
```
- title: "Parity Fixture" [url=PRIMARY/]
- navigation "Main" [ref=e1]:
  - link "Home" [ref=e2]
  - link "Docs" [ref=e3]
- main:
  - heading "Sign up" [level=1]
  - form:
    - label:
      - text: "Email"
      - textbox "Email" [ref=e4] [placeholder="you@x.com"]
    - label:
      - checkbox "Accept terms" [ref=e5]
      - text: "Accept terms"
    - combobox "Plan" [ref=e6]:
      - option "Free"
      - option "Pro" (selected)
      - option "Team"
    - textbox "Bio" [ref=e7]: "hi"
    - button "Create account" [ref=e8]
    - button "Disabled" [ref=e9] [disabled]
  - list:
    - listitem "One" [ref=e10]
    - listitem "Two" [ref=e11]
  - paragraph:
    - text: "Plain  bold  text."
    - image "Logo"
  - button "Far away" [ref=e12]
```

`showHidden` probe:
```
- button [ref=e18] [hidden]: "Hidden btn"          <- display:none button; its name is "" (hidden), text becomes the value
- generic [hidden]:
  - link "hidden link" [ref=e19] [hidden]
- generic [hidden]:                                <- aria-hidden div
  - text: "ah child"
  - button "ah btn" [ref=e20]                      <- no [hidden]: aria-hidden on an ancestor is ignored
```

Other probes: `canvas [ref=e3] [size=50x30]`, `generic "a b c d" [ref=e2] [scrollable]`, `textbox "Pw" [ref=e11]: "[redacted]"`, `listbox [ref=e12]:` / `option "Owned" [ref=e13] [selected]` (aria-owns), `checkbox "Custom cb" [ref=e16] [checked] [disabled]`, `button "fs btn" [ref=e17] [disabled]` (disabled fieldset), `text: "line1\nline2 \"q\""` (`<pre>`), shadow `region "Card" [ref=e1]:` with its inner controls.

## 14. Known Aside bugs (parity decisions for cmux)

1. The title is not escaped. `escape` misses `\`, CR, and TAB.
2. `mergeStrings` adds double spaces and spaces the page does not render between inline elements.
3. Pass B drops ref'd unnamed generics that have ≤1 ref'd child or no children. This leaves holes in the ref numbers and removes clickable icon divs. A generic ignores `aria-label`.
4. `showHidden` shows only hidden elements that carry refs. An `aria-hidden` element with no element children is never walked. `isVisible` ignores `aria-hidden` on an ancestor.
5. Table, row, and cell structure is never emitted (`tr`, `td`, and `th` are generic). The table, fieldset, and figure name branches are dead.
6. Name from content skips the text of nested generic elements (`listitem "first"` with `: "first  bold"`).
7. A textbox value becomes the name when there is no name, and it is hidden when it equals the name.
8. Interactive mode and scoped snapshots append child frames as nameless orphan iframes. Scoped snapshots include frames outside the scope.
9. A scoped snapshot makes every other ref stale.
10. Frame prefixes are not stable (registration order, stale frames after reload).
11. The URL tracking-parameter delete skips a parameter, and the query encoding changes.
12. The diff has no context lines, the zero-count start is not decremented, the first diff is against `""`, and the comparison ignores the options and URL of the previous snapshot.
13. The maxChars hint always says "even smaller maxDepth". The limit applies to each frame, not to the final text.
14. The implicit-role selector fallback is unreachable.
15. `input type=image` and `type=reset` are textboxes.
16. The `deref` fallback cannot match names longer than 100 characters.
17. Focus inside a shadow root marks the host.
18. `[expanded]`, `[pressed]`, the values of progress and slider, and descriptions are never rendered.

## 15. Out of scope

`capture: true` (passive capture): it uses a separate registry, redacts values by input type, autocomplete tokens, field labels, secret patterns, and Luhn card numbers (`[redacted:capture]`), skips password-manager frames, and returns redaction stats. The REPL `snapshot()` does not use it. Only the always-on password `[redacted]` rule above applies to REPL output.
