// One picker's row geometry, measured in a real browser (picker-row-geometry.test.ts).
//
// The rule (leo-workspace design/grid.md 5.3, "Every row in a picker"): every row in a picker shares
// one icon column and one text inset; row rhythm is even inside a section, and a section boundary
// that adds space shows a separator; a subtitle that equals its title is not shown. A picker joins
// the check by listing its selectors as a `PickerRowCase`; nothing here knows any one picker.
//
// Positions are in CSS px from the menu's left edge. Text is measured where its first line box of
// glyphs starts (a Range over the label), not where its element's padding box starts.

import type { Page } from "playwright";

export type PickerRowCase = {
  /** The test's name for it. */
  name: string;
  /** Gallery entry and variant that render the picker. */
  entry: string;
  variant: string;
  /** Opens the picker when the variant's own play leaves it closed. */
  open?(page: Page): Promise<void>;
  /** The picker's popup. */
  menu: string;
  /** Its rows, inside `menu`. */
  row: string;
  /** A row's leading icon box, inside the row (a row may have none). */
  icon: string;
  /** A row's title, inside the row. */
  title: string;
  /** A row's subtitle, inside the row, when it can have one. */
  subtitle?: string;
  /** Containers that make a section (rows in different ones are in different sections). */
  section?: string;
  /** Rows that open a section under a heading of their own (drawn by the row, e.g. a ::before). */
  sectionStart?: string;
  /**
   * "fail" holds the picker to the rule. "warn" (an audit that still has breaks) prints what it
   * measured and passes, until the PR that fixes it flips it.
   */
  level: "fail" | "warn";
};

export type PickerRow = {
  label: string;
  /** Icon box left and width; undefined for a row with no icon. */
  iconLeft?: number;
  iconWidth?: number;
  textLeft: number;
  top: number;
  bottom: number;
  section: number;
  /** The subtitle's text when the row shows one. */
  subtitle?: string;
};

export type PickerBoundary = { after: number; gap: number; separator: boolean };

export type PickerGeometry = { rows: PickerRow[]; boundaries: PickerBoundary[] };

/** Reads the open picker's rows. */
export async function measurePickerRows(
  page: Page,
  { open: _open, ...selectors }: PickerRowCase,
): Promise<PickerGeometry> {
  // Only plain values cross into the page; `open` runs on this side.
  return page.evaluate((item) => {
    const menu = document.querySelector<HTMLElement>(item.menu);
    if (!menu) throw new Error(`no menu ${item.menu}`);
    const origin = menu.getBoundingClientRect().left;
    const visible = (element: Element) => {
      const box = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return box.width > 0 && box.height > 0 && style.visibility !== "hidden" && style.display !== "none";
    };
    const rows = [...menu.querySelectorAll<HTMLElement>(item.row)].filter(visible);
    const textStart = (element: Element) => {
      const range = document.createRange();
      range.selectNodeContents(element);
      const first = [...range.getClientRects()].find((rect) => rect.width > 0);
      return (first ?? element.getBoundingClientRect()).left - origin;
    };
    // A hairline: a border on a side, or a pseudo-element drawn with height or a border.
    const ruled = (element: Element | null, side: "top" | "bottom") => {
      if (!element) return false;
      const own = getComputedStyle(element);
      if (Number.parseFloat(own.getPropertyValue(`border-${side}-width`)) > 0) return true;
      for (const pseudo of ["::before", "::after"]) {
        const style = getComputedStyle(element, pseudo);
        if (style.content === "none" || style.content === "normal" || style.display === "none") continue;
        if (Number.parseFloat(style.height) > 0 || Number.parseFloat(style.borderTopWidth) > 0) return true;
        if (Number.parseFloat(style.borderBottomWidth) > 0) return true;
      }
      return false;
    };
    // Visible elements between two rows in document order, not inside either or around the second.
    const between = (a: Element, b: Element) => {
      const found: Element[] = [];
      const walker = document.createTreeWalker(menu, NodeFilter.SHOW_ELEMENT);
      walker.currentNode = a;
      let node = walker.nextNode() as Element | null;
      while (node && node !== b) {
        if (!a.contains(node) && !node.contains(b) && visible(node)) found.push(node);
        node = walker.nextNode() as Element | null;
      }
      return found;
    };
    let section = 0;
    const measured = rows.map((row, index) => {
      const previous = rows[index - 1];
      if (previous) {
        const container = (element: Element) => (item.section ? element.closest(item.section) : null);
        const headed = item.sectionStart ? row.matches(item.sectionStart) : false;
        if (headed || container(previous) !== container(row) || between(previous, row).length > 0) section += 1;
      }
      const box = row.getBoundingClientRect();
      const icon = row.querySelector(item.icon);
      const iconBox = icon && visible(icon) ? icon.getBoundingClientRect() : undefined;
      const title = row.querySelector(item.title) ?? row;
      const subtitle = item.subtitle ? row.querySelector(item.subtitle) : null;
      // A subtitle drawn from an attribute (`content: attr(data-path)`) has no text node.
      const subtitleText =
        subtitle && visible(subtitle) ? subtitle.textContent || subtitle.getAttribute("data-path") || "" : undefined;
      return {
        label: (title.textContent ?? "").trim(),
        iconLeft: iconBox ? iconBox.left - origin : undefined,
        iconWidth: iconBox?.width,
        textLeft: textStart(title),
        top: box.top,
        bottom: box.bottom,
        section,
        subtitle: subtitleText,
      };
    });
    const boundaries: { after: number; gap: number; separator: boolean }[] = [];
    for (let index = 1; index < rows.length; index += 1) {
      if (measured[index]!.section === measured[index - 1]!.section) continue;
      const a = rows[index - 1]!;
      const b = rows[index]!;
      const container = (element: Element) => (item.section ? element.closest(item.section) : null);
      const inBetween = between(a, b);
      const separator =
        (item.sectionStart ? b.matches(item.sectionStart) : false) ||
        inBetween.some(
          (element) => element.getBoundingClientRect().height <= 2 || ruled(element, "top") || ruled(element, "bottom"),
        ) ||
        ruled(container(a), "bottom") ||
        ruled(container(b), "top");
      boundaries.push({ after: index - 1, gap: measured[index]!.top - measured[index - 1]!.bottom, separator });
    }
    return { rows: measured, boundaries };
  }, selectors);
}

/** What breaks the rule, as sentences; empty when the picker keeps it. */
export function pickerRowProblems(geometry: PickerGeometry, tolerance = 0.5): string[] {
  const problems: string[] = [];
  const { rows } = geometry;
  if (rows.length < 2) return [`only ${rows.length} row(s) to compare`];
  const near = (a: number, b: number) => Math.abs(a - b) <= tolerance;
  const px = (value: number) => `${Math.round(value * 100) / 100}px`;
  const first = rows[0]!;
  for (const row of rows.slice(1))
    if (!near(row.textLeft, first.textLeft))
      problems.push(`"${row.label}" text starts at ${px(row.textLeft)}, "${first.label}" at ${px(first.textLeft)}`);
  const withIcon = rows.filter((row) => row.iconLeft !== undefined);
  const lead = withIcon[0];
  if (lead)
    for (const row of withIcon.slice(1)) {
      if (!near(row.iconLeft!, lead.iconLeft!))
        problems.push(
          `"${row.label}" icon box starts at ${px(row.iconLeft!)}, "${lead.label}" at ${px(lead.iconLeft!)}`,
        );
      if (!near(row.iconWidth!, lead.iconWidth!))
        problems.push(`"${row.label}" icon box is ${px(row.iconWidth!)} wide, "${lead.label}" ${px(lead.iconWidth!)}`);
    }
  // Rhythm: inside a section, the space between rows is one value, and rows of one height share a pitch.
  const gaps: number[] = [];
  for (let index = 1; index < rows.length; index += 1) {
    const [a, b] = [rows[index - 1]!, rows[index]!];
    if (a.section !== b.section) continue;
    const gap = b.top - a.bottom;
    gaps.push(gap);
    if (gaps.length > 1 && !near(gap, gaps[0]!))
      problems.push(`the gap above "${b.label}" is ${px(gap)}, the section's first gap ${px(gaps[0]!)}`);
  }
  const rowGap = gaps[0] ?? 0;
  for (const boundary of geometry.boundaries)
    if (!near(boundary.gap, rowGap) && !boundary.separator)
      problems.push(
        `a ${px(boundary.gap)} blank gap after "${rows[boundary.after]!.label}" (rows are ${px(rowGap)} apart) with no separator`,
      );
  for (const row of rows)
    if (row.subtitle !== undefined && row.subtitle.trim() === row.label)
      problems.push(`"${row.label}" repeats its title as its subtitle`);
  return problems;
}

/** One line per row, for a warn-level audit's log. */
export function describePickerRows(geometry: PickerGeometry): string {
  return geometry.rows
    .map(
      (row) =>
        `  s${row.section} icon ${row.iconLeft?.toFixed(2) ?? "-"}+${row.iconWidth?.toFixed(2) ?? "-"} text ${row.textLeft.toFixed(2)} h ${(row.bottom - row.top).toFixed(2)} "${row.label}"`,
    )
    .join("\n");
}
