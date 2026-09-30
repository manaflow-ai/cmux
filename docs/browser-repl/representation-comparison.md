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

## After: cmux at 039b111 (2026-09-30)

Items 1 to 9 of "cmux must" are implemented (commit 039b111; spec in
[README.md](README.md#snapshot)). Item 10 and 11 are kept: refs are
unchanged and the guide now says they stay valid until the element is
removed; the password mask and state set are unchanged. Rerun of
`node tests/browser-parity/compare/run.mjs` (same harness, same tools; cmux on
the dev driver). Amazon refused WebKit in this run, so its live and frozen
rows show the error page for every tool and are left out below; the Amazon
figures come from the app (WKWebView, tag brepl-v24) instead.

| measure | cmux before (8c5ef2c) | cmux after | cmux-i before | cmux-i after |
| --- | ---: | ---: | ---: | ---: |
| Wikipedia tokens | 19k | 19k | 9.1k | 9.8k |
| HN tokens | 3.9k | 3.3k | 2.9k | 2.9k |
| GitHub tokens | 18k | 17k | 9.2k | 9.8k |
| MDN tokens | 1.0k | 1.2k | 749 | 1.0k |
| tokens per addressable visible element (wikipedia, hn, github, mdn, amazon) | 34.7 | 29.2 | 19.9 | 17.1 |
| GitHub leaked interactive items | 28/607 | 0/536 | 28/607 | 0/536 |
| Wikipedia / MDN leaked interactive items | 3/698, 1/56 | 3/698, 2/56 | 3/698, 1/56 | 3/698, 2/56 |
| recall, live (micro) | 100% | 100% | 100% | 100% |
| structure probes passed | 33/36 | 35/36 | 25/36 | 29/36 |
| small form: output after one action | diff, 63% of full | diff, 46% | full tree (100%) | diff, 55% |
| big page: output after one action | diff, 3% | diff, 2% | diff, 6% | diff, 5% |

Probes that changed: `select-options` and `table-header` now pass; cmux-i
now passes heading and landmark probes. `link-target` still fails by design:
URLs print by default only for links with no name or an image-only name,
and the probe asks for the URL of a named link. The per-element token cost
fell because clipped links, punctuation lines and most URLs are gone; MDN and
the interactive views grew slightly because select options, headings and
landmarks now print.

The same four live pages on the app (brepl-v24, 1280x800), bytes of
`snapshot()` against Aside's `snapshot(page).tree`:

| page | cmux | Aside | delta | cmux `{ interactive }` | cmux `{ viewport }` |
| --- | ---: | ---: | ---: | ---: | ---: |
| Wikipedia | 62,367 | 69,213 | -9.9% | 29,618 | 6,663 |
| Hacker News | 9,009 | 11,770 | -23.5% | 7,876 | 6,668 |
| GitHub | 61,812 | 64,244 | -3.8% | 32,496 | 6,652 |
| Amazon | 59,748 | 62,566 | -4.5% | 42,586 | 8,614 |

Amazon's nav belt: 11 of its 30 links print; the 19 its overflow box cuts
off are left out (item 1). Its department select prints as one line with 10
options and `+N more` (item 3).

## Live ChatGPT for Chrome (2026-09-30)

This round runs the real ChatGPT for Chrome runtime, not the offline stand-ins.
[chatgpt-live.ts](../../tests/browser-parity/compare/chatgpt-live.ts) drives the
installed runtime through the reference client in `cmux-browser-cli`
(`CuaReferenceClient`, ChatGPT-account login). It works in the user's Chrome,
inside the session group "🧪 cmux parity". All pages come from one approved
disposable origin (`127.0.0.1:18911`). Cross-origin frames point at a second,
unapproved loopback origin. The run opens no live sites and uses no raw CDP,
downloads, history or uploads. Every tab it opens is closed in `finally`.
cmux is `944344b` (all nine "cmux must" fixes). Pages: the 12 fixture pages and
the 9 frozen corpus pages in `tests/browser-parity/fixtures/corpus`. All tools
load the corpus pages with the same policy, which blocks their off-site images.

Tools: `chatgpt-live-ax` is `tab.ax.get("state",{disableDiffing:true})` in the
default AX mode. `chatgpt-live-pw` is `tab.playwright.domSnapshot()`.
`chatgpt-live-dom` is `tab.dom_cua.get_visible_dom()`. `dom_cua` exists only in
the legacy mode (`BROWSER_USE_TINYSKY_ENABLED=0`), so the script captures it in a
second pass. Neither mode asked for any approval.

| metric (fixtures + corpus) | cmux | cmux-i | chatgpt-live-ax | chatgpt-live-dom | chatgpt-live-pw | aside | pw-mcp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| tokens, 12 fixtures | 2.7k | 2.0k | 4.8k | **1.3k** | 1.9k | 2.5k | 4.0k |
| tokens, 9 corpus pages | 66k | 41k | 111k | **28k** | 150k | 77k | 211k |
| tokens per addressable element, corpus | 29.8 | **18.4** | 50.3 | 35.7 | no refs | 35.0 | 96.9 |
| recall, fixtures | **100%** | **100%** | 96.7% | 80.0% | 0% (mentions 95%+) | 93.3% | 96.7% |
| recall, corpus | 99.6% | 99.6% | **99.7%** | 35.9% | 0% (mentions 99.9%) | 99.1% | 98.4% |
| recall, corpus first screen | 99.6% | 99.4% | **99.7%** | 95.7% | 0% | 98.7% | 98.8% |
| leaked hidden targets, corpus | 3.5% (89) | 3.5% (89) | 4.5% (115) | **0.2% (2)** | n/a | 4.6% (118) | 1.4% (35) |
| hidden text shown, corpus | **3.6%** | **3.6%** | **3.6%** | 3.9% | 6.5% | 5.2% | 6.5% |
| structure probes (36) | **35** | 29 | 22 | 14 | 24 | 24 | 29 |
| password value shown | no (`********`) | no | no (`<redacted>`) | no | no | no | **yes** |
| after fill + check + submit: printed | diff, **383 B** | diff, 334 B | full tree, 1,242 B | full list | full tree | diff, 420 B | changed subtree, 797 B |
| ... shows value / check / submit text | yes / yes / yes | yes / yes / **no** | redacted / yes / yes | n/a | n/a | yes / yes / yes | yes / yes / yes |
| renamed element keeps its ref | yes | yes | yes | yes | no refs | no | no |
| stale ref | fails fast | fails fast | fails fast ("Accessibility element 5 is stale or missing") | n/a | n/a | fails fast | waits until timeout |

The live ChatGPT flow used `ax.setValue`, `ax.click` and `ax.click`, then `tab.ax.get()`.
Every step succeeded, and the page showed "Submitted me@x.com tos=true plan=Pro".
On this 1.2 KB page the renderer's minimum saving (1,000 bytes) is not met,
so it printed the full tree again. The Email field prints as
`Value: <redacted>` because its name matches the credential pattern. The model
sees the check and the result text, but it cannot see the value it typed.

### The offline stand-ins against live output

All figures below use `results/summary.md`, "Offline stand-ins vs live
ChatGPT". The harness strips URLs, ports, tab ids and AX id numbers first.

- **AX text (offline renderer vs live):** 14 of 21 pages are identical. Six
  pages differ by 1 to 6 lines, and the corpus Vercel page has 11 more lines of
  lazy content live. Live keeps the space before the comma of a label-derived
  name (`Name , ID: name`) and a double space in
  `Description:  Accept terms`. Live prints `Value: <redacted>` for the
  password, where the offline builder omits the value. The nested page differs
  only by its served `/pages/` URLs. The live service keeps one id space
  per tab across navigations, so on a reused tab the ids start above 0. This does
  not change any metric: every earlier chatgpt-ax figure stands within 1% of
  live.
- **`get_visible_dom()` (spec reproduction vs live):** identical on 9 of 21
  pages. Live adds `indeterminate="true"` and `value="<redacted>"`, and it drops
  `value="on"` on checkboxes and radios. On long pages live lists more elements
  (up to +52%, corpus Books) because the user's Chrome window is taller than the
  harness's 800 px. The reproduction therefore under-reports dom_cua's recall,
  but not by a large amount (corpus 31% to 36%).
- **`domSnapshot()` (reproduction vs live):** identical on 9 pages. Live adds
  `[id="…"]` to iframe lines. Live also redacts the password (`<redacted>`). The
  reproduction printed `hunter2`, so its earlier security-probe failure was an
  error in the reproduction. Live passes that probe (24/36, not 23).
- **Frames:** live read the unapproved cross-origin frames (the frames fixture,
  and all three alternating-origin levels of the nested page) and asked for no
  approval. The approval gate covers top-level page access. It does not cover
  frame content. The closed shadow root is missing live, the same as offline.

### Excerpts

States form (cmux, then live AX, live `dom_cua`, live `domSnapshot`):

```
- textbox "Name" [ref=e2] [required]
- textbox "Code" [ref=e3] [invalid]: "x1"
- textbox "Account" [ref=e4] [readonly]: "42"
- textbox "Secret" [ref=e5]: "********"
- checkbox "Some selected" [ref=e6] [checked=mixed]
- combobox "Size" [ref=e7] [options: S, M, L]: "M"
```

```
				8 text field (settable) Name , ID: name
				11 text field (settable) Code , Value: x1, ID: code
				14 text field Account , Value: 42, ID: account
				17 text field (settable) Secret , Value: <redacted>
			18 checkbox (settable, integer) Description:  Some selected, Value: 2, ID: mixed
			19 pop up button (collapsed, settable) Description: Size, Value: M, ID: size, Secondary Actions: Expand
				20 menu
					21 S
					22 (selected) M
					23 L
```

```
<input node_id=1 required="true" />
<input node_id=2 value="x1" />
<input node_id=3 value="42" readonly="true" />
<input node_id=4 type="password" value="<redacted>" />
<input node_id=5 type="checkbox" indeterminate="true" />
<select node_id=6 aria-label="Size" value="M">S M L</select>
```

```
- text: Name
- textbox "Name"
- text: Code
- textbox "Code": x1
- textbox "Secret": <redacted>
- checkbox "Some selected" [checked=mixed]
```

Hacker News story (corpus), cmux and live AX:

```
- text: "1."
- link "upvote" [ref=e11]
- link "Livenerf: Has Opus 5.5 been nerfed yet?" [ref=e12]
- link "github.com/ninjahawk" [ref=e13]
- text: "334 points by"
- link "bryan0" [ref=e14]
- link "5 hours ago" [ref=e15]
- link "hide" [ref=e16]
- link "143 comments" [ref=e17]
```

```
				27 cell
					28 link Value: news.ycombinator.co…, ID: up_49901736
				29 cell
					30 link Description: Livenerf: Has Opus 5.5 been nerfed yet?, Value: github.com/ninjahaw…
					31 text  (
					32 link Description: github.com/ninjahawk, Value: news.ycombinator.co…
					33 text )
			34 row
				35 cell
					36 text 334 points
					37 text  by
					38 link Description: bryan0, Value: news.ycombinator.co…
```

MDN sidebar disclosure (corpus mdn-iframe), cmux and live AX:

```
      - button [ref=e303] [expanded=false]:
        - link "Guides" [ref=e304]
```

```
			833 button (collapsed) Guides, Secondary Actions: Expand
				834 link Description: Guides, Value: …
```

### Where ChatGPT still beats cmux

- **Corpus recall and leaks.** Live AX addresses 99.7% of corpus targets and
  cmux addresses 99.6%. The gap is the 4 MDN sidebar disclosures that cmux prints
  without a name (excerpt above). The match counts an unnamed `button` as a miss,
  and a model has to guess from the child link. On leaks, cmux (3.5%) beats live
  AX (4.5%), but Playwright MCP (1.4%) and `dom_cua` (0.2%) beat cmux. 84 of
  cmux's 89 corpus leaks are zero-width Wikipedia citation backlinks ("Jump
  up"). Playwright's snapshot keeps 4 of them, which suggests that it drops elements with an empty box.
- **Destinations of named links.** Every live ChatGPT format tells the model
  where a link goes: AX gives a 20-character `Value: host/path…`, `dom_cua` and
  `domSnapshot` give the full `href`. cmux prints `[url=…]` only for unnamed or
  image-only links, so the `link-target` probe is the only one of 36 that cmux
  fails. On HN, the model cannot tell that the title link leaves the site and
  the comment link does not.
- **Cheapest first screen.** `dom_cua` costs 28k tokens on the corpus, 30% less
  than cmux-i. It has 95.7% first-screen recall and almost no leaks. cmux's
  `{ viewport: true }` (measured in the app in the section above) is its
  answer, but this harness does not score it yet.
- **One id space per tab.** Live AX ids continue across navigations in a tab, so
  an id from the previous page can never name an element on the new page. cmux
  refs also continue across documents (scenario 17). This is a tie.
- **Typed credentials.** Live AX, `dom_cua` and `domSnapshot` redact any field
  whose attributes match the credential pattern (email, phone, OTP), including
  what the agent typed. cmux shows `me@x.com`. This is better for checking the
  agent's own input, and weaker if a page pre-fills another user's data.

Where cmux is ahead: 35 of 36 structure probes against 22 (live AX: no
`required`/`invalid`/`readonly`, landmarks shown as `container`, placeholder
names lost, `contenteditable` not marked editable). Its output is 41% smaller
than live AX on the corpus (66k against 111k tokens), and cmux-i costs 18.4
tokens per addressable element against 50.3. After an action it prints a
383-byte diff where live AX reprints the 1,242-byte tree. It reaches the closed
shadow root, and it does not show a text box that a user extension (React Scan,
see Caveats) injects into the page.

### New cmux must

1. **In interactive mode, the diff after an action must include changed
   non-interactive text.** After the submit, cmux-i printed 334 bytes without
   "Submitted me@x.com …". Aside-i and live AX both show the result text. Print
   added or changed text, status, alert and live-region lines in the
   interactive diff, even when the interactive tree omits them.
2. **Keep the name of an actionable container whose children have refs.** MDN's
   `<summary><a>Guides</a></summary>` prints as `button [ref=e303]
   [expanded=false]` with no name. When the "content name repeats the children"
   rule removes the name, keep the name on a node that has its own ref:
   `button "Guides" [ref=e303] [expanded=false]`.
3. **Drop links and buttons whose own box has zero width or zero height and
   that no child box makes visible.** On the corpus Wikipedia page this removes
   84 of cmux's 89 leaked targets. It brings cmux to Playwright's leak rate
   without dropping focusable skip links, because those are latent, not empty.
4. **Show where off-site links go.** Add `[url=host/…]` (host and first path
   segment) to links whose host differs from the page's host. On HN this marks
   most of the 30 story links and leaves the other 160+ links, which stay on
   the site, unchanged. The
   `link-target` probe (a same-site relative link) still needs
   `{ urls: true }`. This rule gives the model the destination that ChatGPT's
   formats give, at a small part of their cost.
5. **Score `{ viewport: true }` in the harness.** It is cmux's answer to
   `dom_cua` and needs the same recall and leak evidence (a harness change;
   the next round can add it as a tool).

### Caveats for this round

- The live captures ran in the user's own Chrome at its window size. This
  changes only `dom_cua`, which lists the viewport. The React Scan extension
  adds a "React Not Detected" toast to each page, and ChatGPT reads it as page
  content. The harness removes that block (`stripExtensionUi`) before it scores.
- ChatGPT's page evaluation is read-only: setting `innerHTML` fails. The
  ref-stability page (`pages/refs.html`) makes the same mutation when the
  runtime clicks "Mutate", and the other tools use script evaluation.
- The live pages were served on other ports than the harness pages. The ground
  truth comes from the harness's Chrome on identical markup.
- Recompute everything with:
  `/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node --experimental-strip-types tests/browser-parity/compare/chatgpt-live.ts`
  then `node tests/browser-parity/compare/run.mjs --pages fixtures,nest,corpus`.

## After: cmux at 3dfed73 (2026-09-30)

The five "New cmux must" items and last round's leftovers are implemented
(commits bef0349 and 3dfed73). Rerun:
`node tests/browser-parity/compare/run.mjs --pages fixtures,nest,corpus
--skip-tools aside,browser-use,stagehand` (cmux tools and the offline
ChatGPT stand-ins; the live ChatGPT columns are the committed captures).
The harness now also scores `cmux-v`, `snapshot({ viewport: true })`. The
frozen corpus pages now keep same-host links root-relative (they were
absolute, which made every link off-site on the fixture server); markup is
otherwise unchanged.

| metric (corpus unless noted) | cmux before | cmux after | cmux-i after | cmux-v | chatgpt-live-ax | chatgpt-live-dom |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| tokens, 9 corpus pages | 66k | 67k | 42k | **14k** | 111k | 28k |
| recall, corpus | 99.6% | **100%** | **100%** | 31% (viewport only) | 99.7% | 35.9% |
| recall, corpus first screen | 99.6% | **100%** | **100%** | **100%** | 99.7% | 95.7% |
| recall, fixtures | 100% | 100% | 100% | 94% (100% first screen) | 96.7% | 80.0% |
| leaked hidden targets, Wikipedia corpus | 84/698 | 3/597 | 3/597 | 1/112 | 83/700 | 0/119 |
| leaked hidden targets, all corpus | 89 (3.5%) | **8 (0.3%)** | 8 (0.3%) | 1 | 115 (4.5%) | 2 (0.2%) |
| structure probes (36) | 35 | 35 | 29 | 32 | 22 | 14 |
| action flow: cmux-i shows the submit result | no (334 B) | - | **yes (383 B)** | - | yes (1,242 B) | n/a |

- **Interactive diffs carry result text.** After fill, check and submit,
  cmux-i prints `+ - text: "Submitted me@x.com tos=true plan=Pro"` with the
  ancestor lines that locate it.
- **Named disclosures.** MDN's sidebar prints `button "Guides" [ref=…]
  [expanded=false]:` with the link inside; corpus BBC and MDN-iframe recall
  reach 100%.
- **Zero-size links.** A link or button whose box has zero width or height
  is left out unless some content inside it shows (content hidden by
  `clip`/`clip-path`, as screen-reader labels are, does not count). On the
  frozen Wikipedia page this removes the 101 zero-width citation backlinks.
  On live Wikipedia those backlinks are 10x16 boxes that show "a", "b",
  "c" and stay (the frozen page lost the rule that draws them).
- **Off-site destinations.** Links to another site print
  `[url=host/segment/…]` (at most 48 characters): live HN marks its 31
  off-site story and source links, `[url=github.com/ninjahawk/…]`. The
  `link-target` probe (a same-site link) still needs `{ urls: true }`.
- **Viewport scope.** `cmux-v` is 14k tokens on the corpus, half of
  `dom_cua`'s 28k, with 100% first-screen recall against its 95.7%, and 1
  leaked target.

Live pages on the app (tag brepl-v26, 1280x800), bytes of `snapshot()` and
`snapshot({ viewport: true })`, and printed URLs (off-site host form, and
on-site ones for unnamed or image-only links, at most 100 characters):

| page | full | viewport | off-site URLs | on-site URLs | Aside full (previous round) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Wikipedia | 67,997 | 6,678 | 188 | 16 | 69,213 |
| Hacker News | 10,084 | 7,440 | 30 | 1 | 11,770 |
| GitHub | 62,736 | 6,642 | 43 | 27 | 64,244 |
| Amazon | 59,078 | 8,114 | 31 | 0 | 62,566 |

The off-site URLs cost about 9% on Wikipedia (its citations go to other
sites) and little elsewhere; cmux stays below Aside on all four. Aside's
sizes on the corpus are unchanged (it prints no URLs); cmux is below them
on 8 of 9 corpus pages and 3% above on BBC.
