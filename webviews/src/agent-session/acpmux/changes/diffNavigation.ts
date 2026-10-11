// Where j/k (files) and n/p (changes) move the changes view: the next or previous target past
// a reading line in the scrolled body.

/// The reading line sits this far down the body, so a change lands with context above it.
export const READING_LINE = 0.3;

/// The index of the first target below `line` (step 1) or the last one above it (step -1).
/// Tops within a pixel of the line count as the current target, so stepping always moves.
export function stepTarget(tops: readonly number[], line: number, step: 1 | -1): number | undefined {
  if (step === 1) {
    const index = tops.findIndex((top) => top > line + 1);
    return index === -1 ? undefined : index;
  }
  for (let index = tops.length - 1; index >= 0; index -= 1) if (tops[index]! < line - 1) return index;
  return undefined;
}

const isChange = (node: Element | null) => node?.getAttribute("data-line-type")?.startsWith("change-") === true;

/// The first row of each run of changed rows in the open diffs under `body`, top to bottom. A
/// split diff draws a run in both columns; the pair shares a top, so it is one change.
export function changeStarts(body: ParentNode): HTMLElement[] {
  const starts: { row: HTMLElement; top: number }[] = [];
  for (const container of body.querySelectorAll(".acpmux-diff-file diffs-container")) {
    for (const row of container.shadowRoot?.querySelectorAll<HTMLElement>("[data-line][data-line-type]") ?? []) {
      if (!isChange(row)) continue;
      let previous = row.previousElementSibling;
      while (previous && !previous.hasAttribute("data-line") && !previous.hasAttribute("data-separator"))
        previous = previous.previousElementSibling;
      if (!isChange(previous)) starts.push({ row, top: row.getBoundingClientRect().top });
    }
  }
  starts.sort((a, b) => a.top - b.top);
  return starts.filter((start, index) => index === 0 || start.top - starts[index - 1]!.top > 1).map(({ row }) => row);
}

/// Each file's first section, top to bottom. A file edited more than once has a section per edit.
export function fileSections(body: ParentNode): HTMLElement[] {
  const seen = new Set<string>();
  return [...body.querySelectorAll<HTMLElement>(".acpmux-diff-file")].filter((section) => {
    const path = section.dataset.path ?? "";
    if (seen.has(path)) return false;
    seen.add(path);
    return true;
  });
}
