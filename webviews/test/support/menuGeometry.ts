// l10n-allow-file: browser test diagnostics, not shipped UI.
// The geometry of every open menu in a page, measured in a real browser, and the menu rule it is held
// to (leo-workspace design/menus.md; design/grid.md 5.3; schemas/menu-metrics). Leo, 2026-10-30:
// "look for wastage"; 2026-10-22: "THERE'S SO MUCH BULLSHIT PADDING AND WHATNOT LIKE ALL OVER THE
// FUCKIGN PLACE"; 2026-10-29: "misaligned checkmark :( can we all audit the checkmarks and whatnot".
//
// - One text line per menu: every row's label starts at the same x, from the popup's left edge.
// - That x is AppKit's: 15 (no state column, no icons), 22 (a state column), or the icon column + 20
//   (an icon box of 14 and a gap of 6, at 15 or 22): never an empty gutter.
// - A checkmark centres on the state column, 10 from the popup's edge.
// - A one-line row is the menu row token (--ds-control-row) high.
// - A menu opened from a field-like trigger (data-field-trigger) starts at the trigger's leading edge
//   and is at least as wide.
// - Every menu is glass: a translucent fill (alpha under 0.9) over a blur.
import type { Page } from "playwright";

export type MenuRow = {
  label: string;
  height: number;
  /** Where the label's text starts, from the popup's left edge. */
  textX: number | null;
  /** Where a leading icon starts, from the popup's left edge; null without one. */
  iconX: number | null;
  /** The centre of a drawn checkmark, from the popup's left edge; null without one. */
  checkX: number | null;
  multiline: boolean;
};

export type MenuMeasure = {
  name: string;
  popup: { left: number; width: number };
  trigger: { left: number; width: number; field: boolean } | null;
  rows: MenuRow[];
  rowToken: number;
  alpha: number;
  blur: number;
};

/** Measures every visible menu (`role="menu"`) in the page. */
export function measureMenus(page: Page): Promise<MenuMeasure[]> {
  return page.evaluate(() => {
    const visible = (el: Element) => {
      const r = el.getBoundingClientRect();
      const s = getComputedStyle(el);
      return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && s.display !== "none" && s.opacity !== "0";
    };
    // Parts of a row that are not its label: a check, an icon, a shortcut, a hint, a badge.
    const NOT_TEXT =
      '[aria-hidden="true"], svg, img, .ui-menu-check, .ui-menu-icon, .ui-menu-shortcut, .ui-submenu-chevron, ' +
      '[class*="-check"], [class*="-icon"], [class*="emoji"], [class*="-badge"], [class*="-key"], [class*="-hint"], ' +
      '[class*="shortcut"], [class*="-description"], [class*="-detail"], [class*="-meta"], [class*="-tag"]';
    const probe = document.createElement("div");
    probe.style.height = "var(--ds-control-row, 28px)";
    document.body.append(probe);
    const rowToken = probe.getBoundingClientRect().height;
    probe.remove();
    const alphaOf = (color: string) => {
      const m = /\/\s*([\d.]+%?)\s*\)\s*$/.exec(color) ?? /rgba\([^)]*,\s*([\d.]+)\s*\)\s*$/.exec(color);
      if (!m) return color === "transparent" || color === "rgba(0, 0, 0, 0)" ? 0 : 1;
      return m[1]!.endsWith("%") ? Number.parseFloat(m[1]!) / 100 : Number(m[1]);
    };
    const trigger = [
      ...document.querySelectorAll(
        ':is([aria-haspopup], [data-field-trigger]):is([aria-expanded="true"], [data-popup-open])',
      ),
    ].at(-1);
    return [...document.querySelectorAll('[role="menu"]')].filter(visible).map((popup) => {
      const p = popup.getBoundingClientRect();
      const rows = [...popup.querySelectorAll('[role^="menuitem"]')]
        .filter((row) => row.closest('[role="menu"]') === popup && visible(row))
        .map((row): MenuRow => {
          const r = row.getBoundingClientRect();
          let textX: number | null = null;
          let label = "";
          const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            if (!node.textContent?.trim() || node.parentElement?.closest(NOT_TEXT)) continue;
            const range = document.createRange();
            range.selectNodeContents(node);
            const box = range.getBoundingClientRect();
            if (box.width === 0) continue;
            textX = box.left - p.left;
            label = node.textContent.trim().slice(0, 40);
            break;
          }
          const check = [...row.querySelectorAll('.ui-menu-check, [class*="-check"]')].find(
            (el) => visible(el) && (el.textContent?.trim() || el.querySelector("svg")),
          );
          const checkBox = check?.querySelector("svg")?.getBoundingClientRect() ?? check?.getBoundingClientRect();
          const icon = [
            ...row.querySelectorAll('.ui-menu-icon, [class*="-icon"], [class*="emoji"], [class*="-badge"], svg, img'),
          ].find(
            (el) =>
              visible(el) &&
              !el.closest('.ui-menu-check, [class*="-check"], .ui-submenu-chevron, [class*="shortcut"]') &&
              (textX === null || el.getBoundingClientRect().left - p.left < textX),
          );
          const description = row.querySelector('[class*="-description"], [class*="-detail"]');
          return {
            label,
            height: r.height,
            textX,
            iconX: icon ? icon.getBoundingClientRect().left - p.left : null,
            checkX: checkBox ? checkBox.left + checkBox.width / 2 - p.left : null,
            multiline: !!(description && visible(description)) || r.height > rowToken * 1.5,
          };
        });
      const style = getComputedStyle(popup);
      const t = trigger?.getBoundingClientRect();
      return {
        name: `${popup.tagName.toLowerCase()}.${[...popup.classList].join(".")}`,
        popup: { left: p.left, width: p.width },
        trigger: t ? { left: t.left, width: t.width, field: trigger!.hasAttribute("data-field-trigger") } : null,
        rows,
        rowToken,
        alpha: alphaOf(style.backgroundColor),
        blur: Number(
          /blur\(([\d.]+)px\)/.exec(style.backdropFilter || style.getPropertyValue("-webkit-backdrop-filter"))?.[1] ??
            0,
        ),
      };
    });
  });
}

const near = (a: number, b: number, tolerance: number) => Math.abs(a - b) <= tolerance;

/** What a menu breaks of the menu rule, one line each; none when it holds. */
export function menuFindings(menu: MenuMeasure): string[] {
  const findings: string[] = [];
  const rows = menu.rows.filter((row) => row.textX !== null);
  if (rows.length === 0) return findings;
  const xs = rows.map((row) => row.textX!);
  const first = xs[0]!;
  if (xs.some((x) => !near(x, first, 1)))
    findings.push(`labels start at ${[...new Set(xs.map((x) => x.toFixed(1)))].join(", ")}: not one line`);
  const icons = rows.filter((row) => row.iconX !== null);
  const allowed = icons.length > 0 ? [35, 42] : [15, 22];
  if (!allowed.some((x) => near(first, x, 1)))
    findings.push(`labels start at ${first.toFixed(1)}, not ${allowed.join(" or ")}`);
  for (const row of icons)
    if (!near(row.iconX!, 15, 1) && !near(row.iconX!, 22, 1))
      findings.push(`"${row.label}": icon at ${row.iconX!.toFixed(1)}, not 15 or 22`);
  for (const row of rows)
    if (row.checkX !== null && !near(row.checkX, 10, 0.5))
      findings.push(`"${row.label}": check centred at ${row.checkX.toFixed(1)}, not 10`);
  const tall = rows.filter((row) => !row.multiline && !near(row.height, menu.rowToken, 0.5));
  if (tall.length)
    findings.push(`rows ${[...new Set(tall.map((row) => row.height.toFixed(1)))].join(", ")} px, not ${menu.rowToken}`);
  if (menu.trigger?.field) {
    if (!near(menu.popup.left, menu.trigger.left, 1))
      findings.push(`starts ${(menu.popup.left - menu.trigger.left).toFixed(1)} px from its field`);
    if (menu.popup.width < menu.trigger.width - 0.5)
      findings.push(`${menu.popup.width.toFixed(0)} px under a ${menu.trigger.width.toFixed(0)} px field`);
  }
  if (menu.alpha >= 0.9) findings.push(`fill alpha ${menu.alpha}: not glass`);
  if (menu.blur <= 0) findings.push("no backdrop blur: not glass");
  return findings;
}
