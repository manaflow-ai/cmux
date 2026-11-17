// l10n-allow-file: benchmark output, not shipped UI.
// Scratch diagnostic (CURSOR_CENSUS=1 with TRACE=3): where the drawn rows' elements sit (inside `.selectable`,
// inside a clickable thing), and which elements' computed cursor changes when desktop.css's cursor rules are
// swapped for CURSOR_SWAP_CSS.
import type { Page } from "playwright";

export async function reportCursorCensus(page: Page, swapCss: string | undefined) {
  const result = await page.evaluate((swap) => {
    const CLICKABLE =
      'button, a[href], [role="button"], [role="link"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="tab"], [role="option"], [role="treeitem"], [role="switch"], [role="checkbox"], [role="radio"], summary, label';
    const rowEls = Array.from(document.querySelectorAll(".acpmux-row, .acpmux-row *"));
    let inSelectable = 0;
    let inClickable = 0;
    let both = 0;
    let depthSum = 0;
    for (const el of rowEls) {
      const s = !!el.parentElement?.closest(".selectable");
      const c = !!el.parentElement?.closest(CLICKABLE);
      if (s) inSelectable += 1;
      if (c) inClickable += 1;
      if (s && c) both += 1;
      let d = 0;
      for (let p = el.parentElement; p; p = p.parentElement) d += 1;
      depthSum += d;
    }
    const all = Array.from(document.querySelectorAll("*"));
    const before = all.map((el) => getComputedStyle(el).cursor);
    const changed: string[] = [];
    let removed = 0;
    if (swap) {
      for (const sheet of Array.from(document.styleSheets)) {
        let rules: CSSRuleList;
        try {
          rules = sheet.cssRules;
        } catch {
          continue;
        }
        for (let i = rules.length - 1; i >= 0; i -= 1) {
          const rule = rules[i];
          if (!(rule instanceof CSSStyleRule)) continue;
          const text = rule.selectorText.replace(/\s+/g, " ");
          const isInherit = /^:where\(button, a\[href\].*label\) \*$/.test(text) && rule.style.cursor === "inherit";
          const isSelectable = /^:where\(\.selectable, \.selectable \*\)$/.test(text) && rule.style.cursor === "auto";
          if (isInherit || isSelectable) {
            sheet.deleteRule(i);
            removed += 1;
            if (isInherit) {
              const parts = swap.split("}").filter((p) => p.trim());
              for (const part of parts.reverse()) sheet.insertRule(`${part}}`, i);
            }
          }
        }
      }
      all.forEach((el, index) => {
        const now = getComputedStyle(el).cursor;
        if (now !== before[index]) {
          const path: string[] = [];
          for (let p: Element | null = el; p && path.length < 5; p = p.parentElement)
            path.push(`${p.tagName.toLowerCase()}${p.classList.length ? `.${Array.from(p.classList).slice(0, 2).join(".")}` : ""}${p.getAttribute("role") ? `[role=${p.getAttribute("role")}]` : ""}`);
          changed.push(`${before[index]}->${now} ${path.join(" < ")}`);
        }
      });
    }
    return {
      rowElements: rowEls.length,
      inSelectable,
      inClickable,
      both,
      meanDepth: Math.round((depthSum / Math.max(1, rowEls.length)) * 10) / 10,
      allElements: all.length,
      removed,
      changedCount: changed.length,
      changed: [...new Set(changed)].slice(0, 60),
    };
  }, swapCss);
  const out = (line: string) => console.log(`CURSOR-CENSUS ${line}`);
  const { changed, ...summary } = result;
  out(`SUMMARY ${JSON.stringify(summary)}`);
  for (const line of changed) out(`CHANGED ${line}`);
}
