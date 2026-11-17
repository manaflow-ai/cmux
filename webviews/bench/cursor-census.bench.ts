// l10n-allow-file: bench output labels and fixture text, not shipped UI.
// Whether desktop.css's clickable-cursor rules give every element of the agent pane the same computed cursor as
// the rules they replaced (descendant-universal-rules.test.ts): `:where(button, a[href], ...) * { cursor: inherit }`
// became inheritance plus `:where(button, ...) :where(.selectable)`, `:where(.selectable, .selectable *)` became
// `:where(.selectable)` plus `:where(.selectable label) { cursor: inherit }`, and `:disabled:not(fieldset) *`
// became `button:disabled *, select:disabled *, ...`.
// The real pane (test/support/papercutChat.ts) opens the generated ordinary chat (bench/godFixture.ts `small`:
// tool runs, edit and shell turns, a subagent chain, screenshots, code and lists), plus a fixture of the cases the
// rules decide (a field, a selectable box and a disabled control inside clickable things, a drag handle, a
// zoom-in thumbnail). At the tail and at each of SCREENS screens up, it reads every element's computed cursor,
// swaps the current rules for the old ones in the page's own sheets (same place in the cascade), reads again and
// restores, all in one task so the DOM cannot change in between. Prints the elements read and every difference;
// exits 1 when any pane element's cursor differs or a rule to swap is missing. The fixture's differences are
// printed apart (FIXTURE-DIFF): they show the swap takes effect and name the cases whose cursor changes.
//   SCREENS=12 TURNS=80 bun bench/cursor-census.bench.ts
/// <reference types="bun" />
import { chromium } from "./browsers";
import { godLog } from "./godFixture";
import { papercutPane, type PapercutStep } from "../test/support/papercutChat";

const TURNS = Number(process.env.TURNS ?? 80);
const SCREENS = Number(process.env.SCREENS ?? 12);

const CLICKABLE =
  'button, a[href], [role="button"], [role="link"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="tab"], [role="option"], [role="treeitem"], [role="switch"], [role="checkbox"], [role="radio"], summary, label';

/// The cases the rules decide, under the transcript so the pane's own sheets style them.
const FIXTURE = `
<button><span>label</span><svg><path d="M0 0"/></svg></button>
<button style="cursor: zoom-in"><img alt="" src="data:,"><span>thumb</span></button>
<button><input type="text" value="field in a button"><span contenteditable="true">editable</span></button>
<a href="#x"><span>link <b>bold</b></span></a>
<div class="selectable"><p>selectable <em>text</em></p><button><span>btn in text</span></button><a href="#y"><i>link in text</i></a>
  <label>field label <span>inner</span><input type="text"></label></div>
<button><div class="selectable"><span>selectable in a button</span></div></button>
<div role="button"><div class="selectable"><p><span>deep</span></p></div></div>
<div role="option"><span style="cursor: grab">handle <i>in</i></span></div>
<div class="selectable"><div style="cursor: grab"><span>handle in text</span></div></div>
<div class="selectable"><div style="cursor: col-resize"><button><span>btn in resize</span></button></div></div>
<button disabled><span>disabled <b>btn</b></span></button>
<select disabled><option>a</option></select>
<fieldset disabled><legend><span>legend</span></legend><div><span>in fieldset</span><a href="#z"><i>link</i></a></div></fieldset>
<div aria-disabled="true"><span>aria disabled</span></div>
<label><input type="checkbox"><span>choice</span></label>
<label><input type="radio" disabled><span>locked choice</span></label>
<summary><span>summary</span></summary>
<details><summary><span>in details</span></summary><p>body</p></details>
<div inert><button><span>inert</span></button></div>
`;

const log = godLog("small", { turns: TURNS, imageEvery: 10, chainEvery: 40 });
const lead: PapercutStep[] = log.events.map((event) => [
  event.dir,
  event.kind,
  event.msg as Record<string, unknown>,
  event.at,
]);
const prompts = log.events.filter((event) => event.kind === "user_message").length + 1;

type Census = {
  elements: number;
  inClickable: number;
  swapped: number;
  diffs: string[];
  fixtureDiffs: string[];
  missing: string[];
};

const browser = await chromium.launch({ headless: true });
let failed = false;
const seen = new Set<string>();
const fixtureSeen = new Set<string>();
let totalElements = 0;
let totalInClickable = 0;
let totalDiffs = 0;
for (const running of [false, true]) {
  const pane = await papercutPane(() => browser, {
    turns: 1,
    running,
    lead,
    attachPage: 160,
    session: { turnCount: prompts },
    daemonIndexes: true,
    askedPageSize: true,
  });
  try {
    const page = await pane.open({ width: 1100, height: 800 });
    // fixed-wait: a diagnostic, not a gate; let late popups and timers settle before the first read.
    await page.waitForTimeout(500);
    await page.evaluate((html) => {
      const host = document.createElement("div");
      host.id = "cursor-census-fixture";
      host.innerHTML = html;
      (document.querySelector(".acpmux-scroll") ?? document.body).appendChild(host);
    }, FIXTURE);
    for (let screen = 0; screen <= SCREENS; screen++) {
      if (screen > 0) {
        await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          scroller.scrollTop = Math.max(0, scroller.scrollTop - scroller.clientHeight * 0.9);
        });
        // fixed-wait: let older pages land and rows mount before reading.
        await page.waitForTimeout(400);
      }
      // A row shows its actions under the pointer.
      const view = await page.locator(".acpmux-scroll").boundingBox();
      if (view) await page.mouse.move(view.x + view.width / 2, view.y + view.height / 2);
      const census: Census = await page.evaluate((clickable) => {
        const norm = (text: string) => text.replace(/\s+/g, " ").trim();
        type Swap = { rule: CSSStyleRule; from: string; to: string };
        const swaps: Swap[] = [];
        const found = { inherit: 0, selectable: 0, label: 0, disabled: 0 };
        for (const sheet of Array.from(document.styleSheets)) {
          let rules: CSSRuleList;
          try {
            rules = sheet.cssRules;
          } catch {
            continue;
          }
          const walk = (list: CSSRuleList) => {
            for (const rule of Array.from(list)) {
              if (rule instanceof CSSStyleRule) {
                const text = norm(rule.selectorText);
                if (
                  /^:where\(button, a\[href\].*label\) :where\(\.selectable\)$/.test(text) &&
                  rule.style.cursor === "inherit"
                ) {
                  swaps.push({ rule, from: rule.selectorText, to: text.replace(/ :where\(\.selectable\)$/, " *") });
                  found.inherit += 1;
                } else if (text === ":where(.selectable)" && rule.style.cursor === "auto") {
                  swaps.push({ rule, from: rule.selectorText, to: ":where(.selectable, .selectable *)" });
                  found.selectable += 1;
                } else if (text === ":where(.selectable label)" && rule.style.cursor === "inherit") {
                  // The old sheet had no such rule: matching nothing, it drops out.
                  swaps.push({ rule, from: rule.selectorText, to: ":where(.cursor-census-none)" });
                  found.label += 1;
                } else if (
                  text.includes("button:disabled *, select:disabled *, optgroup:disabled *, option:disabled *")
                ) {
                  swaps.push({
                    rule,
                    from: rule.selectorText,
                    to: text.replace(
                      "button:disabled *, select:disabled *, optgroup:disabled *, option:disabled *",
                      ":disabled:not(fieldset) *",
                    ),
                  });
                  found.disabled += 1;
                }
              } else if ("cssRules" in rule) walk((rule as CSSGroupingRule).cssRules);
            }
          };
          walk(rules);
        }
        const missing = Object.entries(found)
          .filter(([, count]) => count !== 1)
          .map(([name, count]) => `${name}=${count}`);
        const all = Array.from(document.querySelectorAll("*"));
        const now = all.map((el) => getComputedStyle(el).cursor);
        for (const swap of swaps) {
          swap.rule.selectorText = swap.to;
          if (norm(swap.rule.selectorText) !== norm(swap.to)) missing.push(`unparsed ${swap.to.slice(0, 60)}`);
        }
        const old = all.map((el) => getComputedStyle(el).cursor);
        for (const swap of swaps) swap.rule.selectorText = swap.from;
        const diffs: string[] = [];
        const fixtureDiffs: string[] = [];
        all.forEach((el, index) => {
          if (now[index] === old[index]) return;
          const path: string[] = [];
          for (let p: Element | null = el; p && path.length < 6; p = p.parentElement)
            path.push(
              `${p.tagName.toLowerCase()}${p.classList.length ? `.${Array.from(p.classList).slice(0, 2).join(".")}` : ""}${p.getAttribute("role") ? `[role=${p.getAttribute("role")}]` : ""}`,
            );
          const line = `old ${old[index]} -> new ${now[index]}: ${path.join(" < ")}`;
          (el.closest("#cursor-census-fixture") ? fixtureDiffs : diffs).push(line);
        });
        return {
          elements: all.length,
          inClickable: all.filter((el) => el.parentElement?.closest(clickable)).length,
          swapped: swaps.length,
          diffs,
          fixtureDiffs,
          missing,
        };
      }, CLICKABLE);
      totalElements += census.elements;
      totalInClickable += census.inClickable;
      totalDiffs += census.diffs.length;
      for (const line of census.diffs) seen.add(line);
      for (const line of census.fixtureDiffs) fixtureSeen.add(line);
      console.log(
        `cursor-census running=${running} screen=${screen} elements=${census.elements} inClickable=${census.inClickable} swapped=${census.swapped} diffs=${census.diffs.length} fixtureDiffs=${census.fixtureDiffs.length}${census.missing.length ? ` MISSING ${census.missing.join(" ")}` : ""}`,
      );
      if (census.missing.length || census.diffs.length) failed = true;
    }
    await page.close();
  } finally {
    await pane.close();
  }
}
await browser.close();
for (const line of seen) console.log(`cursor-census DIFF ${line}`);
for (const line of fixtureSeen) console.log(`cursor-census FIXTURE-DIFF ${line}`);
console.log(
  `cursor-census total elementsRead=${totalElements} inClickable=${totalInClickable} diffs=${totalDiffs} distinct=${seen.size} verdict=${failed ? "MISS" : "PASS"}`,
);
process.exit(failed ? 1 : 0);
