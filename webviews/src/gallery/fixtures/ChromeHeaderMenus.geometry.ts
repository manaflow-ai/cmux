// Fleet/gallery harness helper only. Measures the real DOM; no app observers or idle work.
export type ChromeHeaderGeometry = {
  paneKind: string;
  density: string;
  tabs: number;
  treatment: string;
  width: number;
  height: number;
  addCenterX: number;
  addCenterY: number;
  addTrailingInset: number;
  addWidth: number;
  actionWidth: number;
  titleChevron: boolean;
  addressRow: boolean;
};

/** Run in the gallery browser context before and after changing 1↔3 tabs or hover/focus. */
export function measureChromeHeaderGeometry(fixture: HTMLElement): ChromeHeaderGeometry {
  const header = fixture.querySelector<HTMLElement>(".chrome-header-menu-row");
  const add = fixture.querySelector<HTMLElement>('[data-chrome-trigger="add"]');
  const more = fixture.querySelector<HTMLElement>('[data-chrome-trigger="pane"]');
  if (!header || !add || !more) throw new Error("chrome header has no reserved add/action slot");
  const box = header.getBoundingClientRect();
  const a = add.getBoundingClientRect();
  const m = more.getBoundingClientRect();
  return {
    paneKind: fixture.dataset.paneKind ?? "",
    density: fixture.dataset.density ?? "",
    tabs: Number(fixture.dataset.tabs),
    treatment: header.dataset.tabTreatment ?? "",
    width: box.width,
    height: box.height,
    addCenterX: a.left + a.width / 2 - box.left,
    addCenterY: a.top + a.height / 2 - box.top,
    addTrailingInset: box.right - a.right,
    addWidth: a.width,
    actionWidth: m.width,
    titleChevron: fixture.querySelector('[data-chrome-trigger="title"]') !== null,
    addressRow: fixture.querySelector("[data-chrome-address-row]") !== null,
  };
}

/** A state transition must change title treatment only; the reserved add/action columns stay put. */
export function assertChromeHeaderGeometry(
  before: ChromeHeaderGeometry,
  after: ChromeHeaderGeometry,
  tolerance = 1 / (globalThis.devicePixelRatio || 1),
): void {
  if (before.paneKind !== after.paneKind || before.density !== after.density)
    throw new Error("compare the same pane kind and density");
  const near = (label: string, a: number, b: number) => {
    if (Math.abs(a - b) > tolerance) throw new Error(`${label} moved: ${a} → ${b}`);
  };
  near("header width", before.width, after.width);
  near("header height", before.height, after.height);
  near("add horizontal center", before.addCenterX, after.addCenterX);
  near("add vertical center", before.addCenterY, after.addCenterY);
  near("add trailing inset", before.addTrailingInset, after.addTrailingInset);
  near("add slot width", before.addWidth, after.addWidth);
  near("toolbar slot width", before.actionWidth, after.actionWidth);
  for (const state of [before, after]) {
    near("add shares row center line", state.addCenterY, state.height / 2);
    if (state.titleChevron !== (state.paneKind === "agent")) throw new Error("title chevron must be agent-only");
    if (state.addressRow !== (state.paneKind === "browser"))
      throw new Error("only browser panes get the address toolbar");
  }
}
