// l10n-allow-file: benchmark output, not shipped UI.
// What a mounted row costs to style (transcript-scroll-up.bench.ts TRACE=3): Chromium's selector stats (the
// `disabled-by-default-blink.debug` SelectorStats events DevTools shows as "selector stats"), summed over the
// run by selector, so the rules every inserted element pays show by name; and a census of the drawn rows:
// elements per row kind, and the style rules each kind's elements match.
import type { Page } from "playwright";

export const SELECTOR_STATS_CATEGORIES = ["devtools.timeline", "disabled-by-default-blink.debug"];

type Ev = { name: string; args?: any };
type Timing = Record<string, unknown>;

export function reportSelectorStats(events: Ev[], top = 40) {
  const out = (line: string) => console.log(`SELECTOR-STATS ${line}`);
  const by = new Map<string, { us: number; attempts: number; matches: number; rejects: number }>();
  let recalcs = 0;
  let shown = false;
  for (const e of events) {
    if (e.name !== "SelectorStats") continue;
    const timings: Timing[] = e.args?.selector_stats?.selector_timings ?? [];
    recalcs += 1;
    if (!shown && timings[0]) {
      out(`fields ${JSON.stringify(Object.keys(timings[0]))}`);
      shown = true;
    }
    for (const t of timings) {
      const key = String(t.selector ?? "?");
      const entry = by.get(key) ?? { us: 0, attempts: 0, matches: 0, rejects: 0 };
      entry.us += Number(t["elapsed (us)"] ?? t.elapsed ?? 0);
      entry.attempts += Number(t.match_attempts ?? 0);
      entry.matches += Number(t.match_count ?? 0);
      entry.rejects += Number(t.fast_reject_count ?? 0);
      by.set(key, entry);
    }
  }
  const all = [...by.entries()];
  const totalUs = all.reduce((sum, [, v]) => sum + v.us, 0);
  const totalAttempts = all.reduce((sum, [, v]) => sum + v.attempts, 0);
  out(
    `SUMMARY ${JSON.stringify({ recalcs, selectors: all.length, ms: Math.round(totalUs) / 1000, attempts: totalAttempts })}`,
  );
  // The rules tried on (nearly) every element styled: Chromium found no class, id, tag or attribute
  // bucket for their subject, so each element styled pays them all.
  const most = Math.max(0, ...all.map(([, v]) => v.attempts));
  const everyElement = all.filter(([, v]) => v.attempts >= most * 0.45);
  out(
    `EVERY-ELEMENT ${JSON.stringify({
      selectors: everyElement.length,
      ms: Math.round(everyElement.reduce((sum, [, v]) => sum + v.us, 0)) / 1000,
      share: Math.round((everyElement.reduce((sum, [, v]) => sum + v.us, 0) / Math.max(1, totalUs)) * 100) / 100,
      elementsStyled: Math.round(most / 2),
    })}`,
  );
  for (const [selector, v] of all.sort((a, b) => b[1].us - a[1].us).slice(0, top * 3))
    out(
      `BY-TIME ${JSON.stringify({ ms: Math.round(v.us) / 1000, attempts: v.attempts, matches: v.matches, rejects: v.rejects })} ${selector.slice(0, 200)}`,
    );
  for (const [selector, v] of all.sort((a, b) => b[1].attempts - a[1].attempts).slice(0, top))
    out(
      `BY-ATTEMPTS ${JSON.stringify({ ms: Math.round(v.us) / 1000, attempts: v.attempts, matches: v.matches, rejects: v.rejects })} ${selector.slice(0, 200)}`,
    );
}

/// Each drawn row kind (its article's classes): rows, elements per row, and the style rules its elements
/// match (every selector in the page's sheets tried with `matches`), with the rules matched most.
export async function reportRowCensus(page: Page) {
  const census = await page.evaluate(() => {
    const selectors: string[] = [];
    const walk = (rules: CSSRuleList) => {
      for (const rule of Array.from(rules)) {
        if (rule instanceof CSSStyleRule) {
          for (const one of rule.selectorText.split(/,(?![^()]*\))/)) selectors.push(one.trim());
          if (rule.cssRules?.length) walk(rule.cssRules);
        } else if ("cssRules" in rule && (rule as CSSGroupingRule).cssRules) walk((rule as CSSGroupingRule).cssRules);
      }
    };
    for (const sheet of Array.from(document.styleSheets)) {
      try {
        walk(sheet.cssRules);
      } catch {}
    }
    // The rightmost compound with no class, id or tag (Chromium's universal bucket: tried on every element).
    const universal = selectors.filter((s) => {
      const last = s
        .replace(/::?[\w-]+(\([^)]*\))?$/g, "")
        .split(/[\s>+~]+/)
        .filter(Boolean)
        .at(-1);
      return !!last && !/[.#]|^[a-zA-Z]/.test(last.replace(/:(is|where|not|has)\(.*\)/g, ""));
    });
    const usable = selectors
      .map((s) =>
        s.replace(/::[\w-]+(\([^)]*\))?/g, "").replace(/:(hover|focus|focus-visible|focus-within|active)/g, ""),
      )
      .filter((s) => {
        try {
          document.createElement("div").matches(s || "*");
          return !!s;
        } catch {
          return false;
        }
      });
    const kinds = new Map<
      string,
      { rows: number; elements: number; matched: number; sampled: number; top: Map<string, number> }
    >();
    for (const row of Array.from(document.querySelectorAll<HTMLElement>(".acpmux-row"))) {
      const kind = Array.from(row.classList)
        .filter((c) => c !== "acpmux-row" && !/--older|--before-footer/.test(c))
        .join(".");
      const entry = kinds.get(kind) ?? { rows: 0, elements: 0, matched: 0, sampled: 0, top: new Map() };
      const elements = [row, ...Array.from(row.querySelectorAll("*"))];
      entry.rows += 1;
      entry.elements += elements.length;
      if (entry.sampled < 3) {
        entry.sampled += 1;
        for (const el of elements)
          for (const s of usable)
            if (el.matches(s)) {
              entry.matched += 1;
              entry.top.set(s, (entry.top.get(s) ?? 0) + 1);
            }
      }
      kinds.set(kind, entry);
    }
    return {
      selectors: selectors.length,
      universal: universal.length,
      universalSample: universal.slice(0, 60),
      kinds: [...kinds.entries()].map(([kind, v]) => ({
        kind,
        rows: v.rows,
        elementsPerRow: Math.round((v.elements / v.rows) * 10) / 10,
        rulesMatchedPerRow: Math.round((v.matched / Math.max(1, v.sampled)) * 10) / 10,
        top: [...v.top.entries()].sort((a, b) => b[1] - a[1]).slice(0, 25),
      })),
      tags: (() => {
        const tags = new Map<string, number>();
        for (const el of Array.from(document.querySelectorAll(".acpmux-row, .acpmux-row *"))) {
          const key = `${el.tagName.toLowerCase()}.${Array.from(el.classList).slice(0, 2).join(".")}`;
          tags.set(key, (tags.get(key) ?? 0) + 1);
        }
        return [...tags.entries()].sort((a, b) => b[1] - a[1]).slice(0, 40);
      })(),
    };
  });
  const out = (line: string) => console.log(`ROW-CENSUS ${line}`);
  out(`SHEETS ${JSON.stringify({ selectors: census.selectors, universal: census.universal })}`);
  for (const s of census.universalSample) out(`UNIVERSAL ${s.slice(0, 200)}`);
  for (const kind of census.kinds) {
    out(
      `KIND ${JSON.stringify({ kind: kind.kind, rows: kind.rows, elementsPerRow: kind.elementsPerRow, rulesMatchedPerRow: kind.rulesMatchedPerRow })}`,
    );
    for (const [s, n] of kind.top) out(`KIND-RULE ${kind.kind} ${n} ${s.slice(0, 160)}`);
  }
  for (const [tag, n] of census.tags) out(`TAG ${n} ${tag}`);
}
