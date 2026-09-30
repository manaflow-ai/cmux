# Agent page representations: head-to-head

Measured 2026-09-30 on the same pages within minutes of each other. cmux is
`snapshot()` at `8c5ef2cdb39` (runtime files clean, digest `348a2bebde20`).
The harness is [tests/browser-parity/compare](../../tests/browser-parity/compare);
`results/results.json` holds every number below, `results/summary.md` the full
per-page tables, and `results/raw/` the fixture outputs of every tool.

```sh
./tests/browser-parity/compare/setup.sh     # once: js-tiktoken, Stagehand, browser-use venv
node tests/browser-parity/compare/run.mjs   # about 6 minutes; --pages fixtures,nest,live, --only NAME
```

## Tools

| id | representation | how it was captured |
| --- | --- | --- |
| cmux | `snapshot()` | run: Resources/browser-repl runtime on Playwright WebKit through `lib/dev-driver.mjs` |
| cmux-i | `snapshot({ interactive: true })` | run, same |
| aside | `snapshot(page)` | run: `aside repl` one-shot (Aside CLI 1.26.916.1741), own tab in Aside Browser |
| aside-i | `snapshot(page, { interactive: true })` | run, same |
| chatgpt-ax | ChatGPT for Chrome `tab.ax` state text | run: the plugin's own WASM renderer (openai-bundled/chrome 26.917.71314) on headless Chrome, via the reference script from `2e4c54b6fa8` |
| chatgpt-dom | `tab.dom_cua.get_visible_dom()` | reproduced from [chatgpt-ax-spec.md](chatgpt-ax-spec.md) section 7, not run |
| chatgpt-pw | `tab.playwright.domSnapshot()` | reproduced from spec section 8 over `_snapshotForAI()`, not run |
| pw-mcp | Playwright MCP `browser_snapshot` (`page._snapshotForAI()`, Playwright 1.57) | run on headless Chrome, wrapped in the MCP page-state header |
| browser-use | `dom_state.llm_representation()` (browser-use 0.13.10) | run: isolated venv, headless Chrome, no LLM |
| stagehand | `page.snapshot({ includeIframes: true }).formattedTree` (Stagehand 4.1.0) | run: headless Chrome for Testing with its extension, no LLM |

Every Chrome-based tool used a fresh throwaway profile, a 1280x800 viewport and
a desktop Chrome user agent. The ChatGPT, Playwright and ground-truth captures
read the same page load.

## Pages

All 11 fixture pages (`tests/browser-parity/fixtures`, two origins), the
nested-frame page (`compare/pages/top.html`: three levels of alternating
origins, a closed shadow root at the bottom, a srcdoc frame), and six live
pages: Wikipedia (WebKit), Hacker News, github.com/manaflow-ai/cmux, the MDN
URL given (it is a 404 page, a real MDN page with MDN's navigation), Amazon
search, and vercel.com. `amazon-frozen` is Chrome's DOM of the Amazon page with
scripts removed, served locally so every engine sees the same markup; it exists
because Amazon refuses Playwright WebKit on some runs (it did not on the final
run).

## Metrics

- **Size**: UTF-8 bytes and o200k_base tokens (js-tiktoken, real tokenizer).
- **Ground truth** (headless Chrome, every frame, open and closed shadow roots):
  links, buttons, form controls, summaries, widget roles, contenteditable
  roots, `onclick` elements and `tabindex >= 0` elements, with an approximate
  accessible name. A click-handler container around other controls is not a
  target. Visible means rendered, not clipped away by an `overflow: hidden`
  ancestor. Skip links, transparent inputs over custom controls and other
  elements a keyboard or pointer can still reach count as neither target nor
  leak.
- **Recall**: share of visible named ground-truth elements that an addressable
  item of the tool names with a compatible role. Lenient also accepts the
  label on the line before or after the item (browser-use puts field labels
  there). In-viewport recall restricts the ground truth to the first screen.
- **Precision / leak**: widget items whose only match is a hidden element
  (items flagged `[hidden]` do not count), and hidden text (12+ characters,
  absent from visible text) that appears in the output.
- **Structure**: 36 probes on the fixtures (section below).
- **Change reporting**: fill Email and check a box on a 9-control form and on
  a ~300-element page; what the tool prints next (its diff when it has one).
- **Ref stability**: rename Beta, insert two buttons before it, remove Alpha;
  compare refs, and resolve the old refs after the new snapshot.

## Results

### Size and cost

Tokens on the live pages all tools captured validly (Wikipedia, HN, GitHub,
MDN, Amazon):

| | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Wikipedia | 19k | 9.1k | 20k | 18k | 33k | 2.5k | 43k | 56k | 4.2k | 38k |
| HN | 3.9k | 2.9k | 4.2k | 3.8k | 6.9k | 3.8k | 11k | 15k | 5.7k | 9.0k |
| GitHub | 18k | 9.2k | 18k* | 17k* | 144k | 4.2k | 39k | 57k | 9.3k | 33k |
| MDN (404) | 1.0k | 749 | 4.1k | 2.3k | 1.9k | 769 | 1.8k | 3.0k | 1.1k | 1.9k |
| Amazon | 19k | 12k | 21k | 17k | 22k | 10k | 129k | 148k | 8.6k | 35k |
| **total** | **60k** | **34k** | 68k | 58k | 208k | 21k | 224k | 278k | 29k | 117k |
| fixtures total | 2.7k | 1.8k | 2.5k | 2.5k | 4.4k | 1.2k | 1.8k | 4.0k | 2.3k | 3.7k |
| **tokens per addressable element** | 34.7 | **19.9** | 40.3 | 34.5 | 117.6 | 60.3 | n/a | 159.0 | 44.0 | 68.1 |

\* Aside Browser used the person's signed-in session, so its GitHub page has
the signed-in header; on vercel.com it was redirected to a team dashboard and
is excluded.

Smallest raw output: chatgpt-dom and browser-use, because both emit only the
viewport (plus 1000 px for browser-use); they pay for it in page-wide recall.
Cheapest per element the model can act on: **cmux-i (19.9)**, then aside-i
and cmux full (about 35). Playwright MCP costs 4.6x cmux: `[cursor=pointer]`,
`/url:` lines (22 to 32% of its tokens), refs on every generic node, and all 60
options of Amazon's department select. ChatGPT AX is 8x cmux on GitHub
because container names concatenate all their descendant text (one line is
37 KB).

### Interactive recall

| | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| fixtures, 90 elements | **100%** | **100%** | 93% | 93% | 97% | 76% | 0% | 97% | 97% (86% strict) | 96% |
| live, 2,301 elements | 95% | 95% | 92% | 92% | **97%** | 18% | 0% | 96% | 34% | 95% |
| live, first screen only | **99%** | **99%** | 96% | 97% | **99%** | 78% | 0% | **99%** | 94% | 97% |

chatgpt-pw mentions 95%+ of names but has no refs, so it addresses nothing.
Per-page misses worth naming: Aside and Stagehand do not descend below the
first nested iframe (the nested page's second and third levels are missing),
Aside also misses the closed shadow root and calls a range input a textbox; ChatGPT AX drops placeholder-only names (`text field (settable)
ph` for "Search here") and loses the closed shadow root; browser-use leaves
the disabled button and the below-the-fold button without an index. On Amazon
cmux (84%) trails ChatGPT AX and Playwright (92 to 93%); on the frozen copy
all three reach 92%, so the gap is live-page variance, not a rule.

### Precision and leaks (live pages)

| | cmux | aside | chatgpt-ax | chatgpt-dom | chatgpt-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| hidden items emitted as targets | 3.6% (80) | 7.3% (161) | 3.7% | 4.2% | n/a | **2.6%** | 5.1% | 3.4% |
| hidden text shown | **6.6%** | 21.6% | 20.2% | **2.7%** | 21.0% | 21.0% | 4.4% | 18.6% |

cmux leaks least hidden text among full-page tools, but not fewest hidden
targets. Of its 80 leaked targets, 73 sit entirely outside an
`overflow: hidden` ancestor: 45 Amazon nav-belt links (`.nav-progressive-content`
at 1280 px) and 28 GitHub `#1234` links in ellipsized commit messages
(`.react-directory-commit-message`). The other 7 are skip links and Vercel's
zero-size theme radios. Every accessibility-tree tool leaks the same ones;
only the geometry-based tools (dom_cua, browser-use) drop them. Aside leaks 81 of 147 targets on MDN (its hidden navigation menus).
Password values: Playwright MCP and ChatGPT `domSnapshot` print `hunter2`;
cmux prints `"********"`, ChatGPT AX and Aside redact.

### Structure fidelity (36 fixture probes)

| category | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| structure (11) | 10 | 2 | 9 | 7 | 4 | 0 | **11** | **11** | 1 | 8 |
| states (13) | **12** | **12** | 7 | 7 | 9 | 4 | 9 | 9 | 6 | 4 |
| frames (4) | **4** | **4** | 3 | 3 | 3 | **4** | 0 | **4** | **4** | 2 |
| shadow (2) | **2** | **2** | 1 | 1 | 1 | 1 | 0 | 1 | **2** | 1 |
| widgets (3) | **3** | **3** | 2 | 2 | 2 | 2 | 1 | 2 | **3** | 2 |
| security (2) | **2** | **2** | **2** | **2** | **2** | 1 | 1 | 1 | **2** | **2** |
| link target (1) | 0 | 0 | 0 | 0 | **1** | **1** | **1** | **1** | 0 | 0 |
| **total** | **33** | 25 | 24 | 22 | 22 | 13 | 23 | 29 | 18 | 19 |

cmux is the only format that prints `required`, `invalid` and `readonly`, and
with browser-use the only one that reaches a closed shadow root. It fails
three probes: link URLs (off by default), collapsed `<select>` options (off by
default; every other format prints them) and table headers (a header row
prints as `row: "User | Action"`, indistinguishable from data; Playwright and
Stagehand keep `columnheader`). cmux-i drops headings, landmarks, lists,
tables and alerts; aside-i keeps headings and landmarks and scores 22.

### Change reporting

| | cmux | cmux-i | aside | aside-i | chatgpt-ax | pw-mcp | others |
| --- | --- | --- | --- | --- | --- | --- | --- |
| small form, printed / full | 63% | 100% (full tree) | **32%** | **32%** | 100% (full tree) | 61% | full tree |
| ~300 elements, printed / full | 3% | 6% | 3% | 3% | **2%** | **2%** | full tree |
| shows the typed value | yes | yes | yes | yes | no (redacted as a credential field) | yes | browser-use, stagehand yes |
| shows the check | yes | yes | yes | yes | yes | yes | |
| shows focus moved | yes | yes | yes | yes | yes | yes | browser-use, stagehand no |

On the big page cmux prints four changed lines with one context line; Aside
prints the same lines under `@@ -48 +48 @@` hunk headers; ChatGPT prints one
`~` line per changed node plus a focus line; Playwright prints the changed
subtree with `ref=eN [unchanged]` stubs. On the small form cmux-i prints the
full tree because its diff saves less than 30%; Aside prints any diff shorter
than the tree. Aside diffs against whatever snapshot came last, so mixing
full and interactive snapshots produces whole-tree diffs; the harness runs
each mode separately to keep that out of the numbers.

### Ref stability

| | cmux | aside | chatgpt-ax | chatgpt-dom | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- |
| renamed element keeps its ref | **yes** (e2) | no (e4 to e11) | **yes** | **yes** | no (e6 to e12) | **yes** | **yes** |
| removed ref reused | no | no | no | no | no | no | no |
| old ref of removed element | fails fast: "ref e1 is stale" | fails fast | n/a | n/a | hangs until timeout | n/a | n/a |
| old ref of renamed element | resolves to it | "stale" | n/a | n/a | hangs until timeout | n/a | n/a |

## Excerpts

The same form region on the index fixture.

```
cmux
- textbox "Email" [ref=e4] [placeholder="you@x.com"]
- checkbox "Accept terms" [ref=e5]
- combobox "Plan" [ref=e6]: "Pro"
- textbox "Bio" [ref=e7]: "hi"
- button "Create account" [ref=e8]
```

```
aside
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
```

```
chatgpt-ax
	8 container
		9 text Email
		10 text field (settable) Email
	11 checkbox (settable, integer) Description: Accept terms, Value: 0, ID: tos
	12 pop up button (collapsed, settable) Description: Plan, Value: Pro, ID: plan, Secondary Actions: Expand
		13 menu
			14 Free
			15 (selected) Pro
			16 Team
	17 text entry area (settable) Description: Bio, Value: hi, ID: bio
```

```
pw-mcp                                          browser-use
- generic [ref=e8]:                             [29]<label />
  - text: Email                                   Email
  - textbox "Email" [ref=e9]:                     |SHADOW(open)|[3]<input id=email type=email
    - /placeholder: you@x.com                         name=email placeholder=you@x.com />
- generic [ref=e10]:                            [32]<label />
  - checkbox "Accept terms" [ref=e11]             [6]<input id=tos type=checkbox name=tos
  - text: Accept terms                                value=on checked=false />
- combobox "Plan" [ref=e12]:                      Accept terms
  - option "Free"                               |SHADOW(open)|*[4]<select id=plan name=plan
  - option "Pro" [selected]                         aria-label=Plan expanded=false compound_components=
  - option "Team"                                   (name=Dropdown Toggle,role=button),(name=Options,
                                                    role=listbox,count=3,options=Free|Pro|Team) />
```

```
stagehand                                       chatgpt-dom
[0-24] LabelText                                <input node_id=3 name="email" placeholder="you@x.com" type="email" />
  [0-25] StaticText: Email                      <input node_id=4 name="tos" type="checkbox" value="on" />
  [0-3] textbox: Email                          <select node_id=5 aria-label="Plan" name="plan" value="Pro">Free Pro Team</select>
[0-6] checkbox: Accept terms                    <textarea node_id=6 aria-label="Bio" name="bio" value="hi">hi</textarea>
[0-4] select: Plan
  [0-36] MenuListPopup
    [0-38] option: Free
```

The first Hacker News story (titles shortened here).

```
cmux                                            aside
- text: "1."                                    - text: "1."
- link "upvote" [ref=e11]                       - link "upvote" [ref=e11]
- link "Livenerf: Has Opus 5.5 ..." [ref=e12]   - link "Livenerf: Has Opus 5.5 ..." [ref=e12]
- text: "("                                     - text: "("
- link "github.com/ninjahawk" [ref=e13]         - link "github.com/ninjahawk" [ref=e13]
- text: ")"                                     - text: ")349 points  by"
- text: "349 points by"                         - link "bryan0" [ref=e14]
- link "bryan0" [ref=e14]                       - link "5 hours ago" [ref=e15]
- link "5 hours ago" [ref=e15]                  - text: "|"
- text: "|"                                     - link "hide" [ref=e16]
- link "hide" [ref=e16]                         - text: "|"
- text: "|"                                     - link "147 comments" [ref=e17]
- link "147 comments" [ref=e17]
```

```
chatgpt-ax
	26 cell
		27 link Value: news.ycombinator.co…, ID: up_49901736
	28 cell
		29 link Description: Livenerf: Has Opus 5.5 been nerfed yet?, Value: github.com/ninjahaw…
		30 text  (
		31 link Description: github.com/ninjahawk, Value: news.ycombinator.co…
		32 text )
```

```
pw-mcp
- 'row "1. upvote Livenerf: Has Opus 5.5 been nerfed yet? (github.com/ninjahawk)" [ref=e32]':
  - cell "1." [ref=e33]
  - cell "upvote" [ref=e34]:
    - link "upvote" [ref=e36] [cursor=pointer]:
      - /url: vote?id=49901736&how=up&goto=news
      - generic "upvote" [ref=e37]
```

```
browser-use                                     chatgpt-dom
	[77]<td />                                  <a node_id=11 href="vote?id=49901736&amp;how=up&amp;goto=news" />
		[79]<a />                               <a node_id=12 href="https://github.com/ninjahawk/livenerf">Livenerf: ...</a>
			Livenerf: Has Opus 5.5 ...          <a node_id=13 href="from?site=github.com/ninjahawk">github.com/ninjahawk</a>
		[83]<a />                               <a node_id=14 href="user?id=bryan0">bryan0</a>
			github.com/ninjahawk
```

Readability: cmux and Aside read as an outline with one element per line and
names in quotes; cmux is flatter (no `label`/`form` wrappers, no option list).
ChatGPT AX spends words on macOS role descriptions and `Description:`/`Value:`
prefixes, and its HN upvote link has no name at all. Playwright MCP nests every
element two or three levels deep in `generic` wrappers. browser-use splits an
element across lines, puts the label on a sibling line and shows no role for
inputs. Stagehand prints `LabelText`, `StaticText` and `MenuListPopup`
internals. dom_cua is HTML the model already knows, but inputs carry no label.

## Ranking

| rank | tool | why |
| --- | --- | --- |
| 1 | **cmux** (full; cmux-i for acting) | 100% fixture recall, 95% live (99% first screen); 33/36 probes, the only one with required/invalid/readonly; stable refs that survive renames and fail fast when stale; 3% diffs with focus; second smallest full-page output and cmux-i is the cheapest per actionable element. Loses on link URLs, select options, table headers, clipped-content leaks and punctuation noise. |
| 2 | Playwright MCP | 97%/96% recall, 29/36 probes, best structure (11/11) and fewest leaked targets, 2% diffs. 4.6x cmux tokens; prints password values; refs change on rename and stale refs hang until timeout. |
| 3 | ChatGPT AX | 97%/97% recall, stable ids, 2% diffs, credential redaction. Largest output on GitHub (144k tokens), landmarks rendered as `container`, placeholder names lost, closed shadow roots removed, and the typed email is hidden from the agent that typed it. |
| 4 | Aside | Size close to cmux (+13%) and readable. Refs change on rename; loses deep frames and closed shadow; misses 6 of 13 state probes; flattens tables to text; leaks MDN's hidden menus; diffs against the previous snapshot of any kind; live pages come from the person's signed-in profile. |
| 5 | Stagehand | 96%/95% recall and stable ids, but twice cmux's size of accessibility internals, no disabled/expanded/pressed, no diff, one nested frame level. |
| 6 | browser-use | Stable backend-node indices and the closed shadow root, compact per screen, but 34% page-wide recall (viewport only), no headings or landmarks, disabled controls unaddressable, no diff. |
| 7 | ChatGPT dom_cua (reproduced) | Smallest; viewport only (18% page-wide), unlabeled inputs, 13/36 probes. |
| 8 | ChatGPT domSnapshot (reproduced) | Readable and structured, but no refs: nothing is addressable. |

## cmux must

Each item is a rule change to `snapshot()` and the measurement it would move.

1. **Drop elements that an `overflow: hidden`/`clip` ancestor clips out entirely.**
   73 of cmux's 80 leaked live targets are this case (45 Amazon nav-belt
   links, 28 ellipsized GitHub `#1234` links). Every accessibility-tree tool
   leaks them; dom_cua and browser-use drop them by geometry. This takes cmux
   from 3.6% to 0.3% leaked targets, below Playwright MCP's 2.6%.
2. **Fold punctuation-only text into its neighbors.** HN has 131 lines like
   `- text: "|"`, `"("`, `")"`: 654 tokens, 17% of cmux's HN output (70 lines on
   Wikipedia). Aside already merges runs (`")349 points  by"`); cmux should
   join adjacent text runs between refs and drop runs of 1 to 3 punctuation
   characters.
3. **Print collapsed `<select>` options inline, capped.** All eight other
   formats show options; cmux shows only the value unless `{ options: true }`
   (probe `select-options` fails). Use one attribute,
   `combobox "Plan" [ref=e6]: "Pro" [options: Free, Pro, Team]`, capped at 10
   with `+N more`, so Amazon's 60-option department select stays one line
   instead of Playwright's 76 option lines.
4. **Keep table header rows distinguishable.** `row: "User | Action"` for a
   `<th>` row reads as data (probe `table-header` fails; Playwright and
   Stagehand keep `columnheader`). Print it as `row (header): "User | Action"`
   or prefix the table with `columns: User | Action`; one token of overhead.
5. **Name unnamed links from their target.** Wikipedia has 15 `link [ref=eN]`
   lines with no name and cmux omits URLs by default, so the model cannot
   tell them apart. Keep URLs off by default (Playwright's `/url:` lines are
   22 to 32% of its tokens; ChatGPT truncates every URL to 20 characters), but
   print `[url=…]` when a link's name is empty or an image alt only. This
   passes the `link-target` probe for the links that need it without the cost.
6. **Keep headings and landmarks in interactive mode.** cmux-i passes 2 of 11
   structure probes; aside-i keeps headings and landmarks and passes 7. One
   line per heading gives the model the page outline: Wikipedia's 18 heading
   lines cost 199 tokens, 2.2% of cmux-i's output there.
7. **Print a changed node once.** cmux prints a `-` and a `+` line per changed
   node; ChatGPT prints one `~` line with the new state, half the bytes for the
   same information. Pair each removal with its insertion when the ref matches
   and print `~ textbox "Email" [ref=e4] [focused]: "me@x.com"`.
8. **Print the diff whenever it is shorter than the tree.** The 30% threshold
   made cmux-i print its full 456-byte tree after one fill on the small form,
   where Aside printed a 32% diff. The threshold protects readability of large
   diffs; apply it only above a size floor (for example 2 KB of tree).
9. **Add a viewport scope.** browser-use and dom_cua are 4 to 8x smaller on
   Wikipedia (4.2k and 2.5k tokens against 19k) with 94% and 78% first-screen
   recall. `snapshot({ viewport: true })` (visible screen plus one screen
   below, same refs) would beat both on recall at similar size.
10. **Keep refs as they are and say so in the guide.** cmux is the only ref
    scheme that both survives renames and fails fast on removed elements;
    Playwright MCP rebinds renamed elements to new refs and hangs until the
    action timeout on stale ones. Document "refs are stable until the element
    is removed" so agents stop re-snapshotting after every action.
11. **Keep the password mask and the state set.** `required`, `invalid`,
    `readonly`, `expanded=false` and `pressed=mixed` are cmux-only or rare
    wins (13-probe states: cmux 12, next best 9), and Playwright MCP prints
    password values. Do not trade these away for size.

## Caveats

- cmux ran on Playwright WebKit (the dev driver), not in the app's WKWebView.
  Amazon refused WebKit on some runs ("Sorry! Something went wrong!"); the
  harness marks such captures `blocked` and excludes them, and
  `amazon-frozen` gives all engines the same markup. The other tools ran on
  Chrome, so layout-dependent differences (line wrapping, font metrics) can
  move a few elements across the viewport edge.
- Aside ran in the person's own Aside Browser profile. Its GitHub page is the
  signed-in variant, and vercel.com redirected to a dashboard (excluded).
  Its raw live outputs are gitignored and not quoted here.
- chatgpt-dom and chatgpt-pw are reproductions from the behavioral spec; the
  real service adds per-frame deadlines and iframe `id`/`name` attributes that
  are not modeled. chatgpt-ax is the real renderer on a clean-room snapshot
  builder.
- The ground-truth accessible name is an approximation. Composite names
  (Amazon price links `$34.99 $34 . 99`, Vercel cards) miss in every tool
  alike, which lowers all live recall figures by the same amount. Role
  matching is lenient across vocabularies (`pop up button` counts as a
  combobox; `generic` does not count as a button).
- Live pages change between runs (HN ranks, Amazon results, A/B variants);
  every tool captured a page within 30 seconds of the others, but numbers
  shift a few percent between runs. Fixture numbers are reproducible.
- The change scenario sets the field value and clicks through page script in
  every tool, so it measures reporting, not input fidelity.
