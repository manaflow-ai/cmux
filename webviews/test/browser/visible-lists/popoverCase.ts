// What the caller cases (a real picker: its trigger opens a Popover around a ui/Combobox) share: open
// the popover as a click would, wait for its rows, and the controls the harness reads from it.
import type { VisibleListControls } from "./case";

/** The agent pane's strings, as its dev server installs them (acpmux/i18n.ts), so rows read as words. */
export async function paneStrings(): Promise<void> {
  const scope = globalThis as { __cmuxPaneStrings?: unknown };
  scope.__cmuxPaneStrings ??= (await import("../../../src/agent-session/acpmux/generated/strings.json")).default;
}

/** Settings' strings, as its dev server installs them (pages/settings/main.tsx). */
export async function settingsStrings(): Promise<void> {
  const { installCatalog } = await import("../../../src/pages/settings/strings");
  const table = (await import("../../../src/pages/settings/generated/strings.json")).default;
  installCatalog(table as Parameters<typeof installCatalog>[0]);
}

/** Frames until `ready()` holds (a popover's first rows, a host's late answer), or throws. */
export async function until(ready: () => boolean, what: string, frames = 600): Promise<void> {
  for (let frame = 0; frame < frames; frame++) {
    if (ready()) return;
    await new Promise((done) => requestAnimationFrame(() => done(undefined)));
  }
  throw new Error(`visible-lists case: ${what} never came`);
}

/** The open combobox's list: its listbox. */
export const listbox = () => document.querySelector<HTMLElement>('[role="listbox"]');

/** The nearest ancestor of the list's rows that scrolls (a windowed list's scroller, a plain list's
 * own box, or the popup around it). */
export function scrollerOf(row: Element | null): HTMLElement {
  for (let node = row?.parentElement ?? null; node; node = node.parentElement) {
    const overflow = getComputedStyle(node).overflowY;
    if ((overflow === "auto" || overflow === "scroll") && node.scrollHeight > node.clientHeight) return node;
  }
  return listbox()!;
}

/** Presses the trigger as the pointer does (pointerdown, then click), then waits for the rows. */
export async function openPopover(trigger: HTMLElement): Promise<void> {
  trigger.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, pointerType: "mouse", button: 0 }));
  trigger.click();
  await until(() => !!listbox()?.querySelector('[role="option"]'), "the popover's rows");
  // Its rows' first measure and the open-at-current scroll.
  for (let frame = 0; frame < 4; frame++) await new Promise((done) => requestAnimationFrame(() => done(undefined)));
}

/** The controls of an open popover's combobox: rows are its options, the list is the popup. */
export function popoverControls(
  rowComponents: readonly string[],
  extra: Pick<VisibleListControls, "changeOne"> = {},
): VisibleListControls {
  const popup = () => listbox()?.closest<HTMLElement>('[role="dialog"]') ?? listbox()!;
  return {
    rowSelector: '[role="option"]',
    // ComboboxItem is Base UI's row (Autocomplete.Item): counted too, so a Combobox with no
    // ComboboxOption (before it windowed) still reports its row renders.
    rowComponents: [...rowComponents, "ComboboxItem"],
    scroller: () => scrollerOf(listbox()?.querySelector('[role="option"]:not(.ui-combobox-pinned *)') ?? null),
    list: popup,
    filter: () => document.querySelector<HTMLElement>('[role="combobox"]')!,
    resizeTarget: popup,
    ...extra,
  };
}
