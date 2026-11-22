// Whether an open popup holds still while the person only looks at it (Leo, 2026-11-22, on the new
// chat's Projects menu growing 315 -> 530 -> 315 px while open: "the shifting projects and sizing of
// stuff. and the shifting of the inner content. we need to prevent this once and for all").
//
// The page side (`installPopupStill`) records, from the first painted frame in which a popup
// matching its selector is visible, each painted frame's box of every such popup and of its rows
// (`[role=option]`, `[role^=menuitem]`, `.acpmux-menu-item`): the row's left and height, and its
// leading and trailing slots (first child's left, last child's right). Reads run after the frame
// painted (paintedFrames.ts). Input the person gives (a key, a typed letter, a press) is marked
// (`window.cmuxPopupStill.mark("input")`, and by itself from capturing listeners).
//
// The node side (`popupMoves`) names every change of those numbers after a popup's first frames
// (src/ui/popupSettle.ts settles a box once it drew the same for two frames) that no input explains
// (POPUP_INPUT_MS after one given to that popup: a key while it is open, a press in it; the press
// or key that opened it explains nothing). A row is matched across frames by its text's start, so a row that
// arrives or leaves late is no move; a row that stays and slides sideways, or grows taller, is.
import type { Page } from "playwright";
import { POPUP_INPUT_MS } from "../../src/ui/popupSettle";

export type PopupBox = { left: number; top: number; width: number; height: number };
export type PopupRow = {
  /** The row's text start, with `#n` for the n-th repeat of the same start in its popup. */
  key: string;
  left: number;
  height: number;
  /** The first child element's left edge; none for a row with no child element. */
  lead?: number;
  /** The last child element's right edge. */
  trail?: number;
  /** Where its first words start: an icon that arrives late before them moves this. */
  text?: number;
};
export type PopupShot = {
  /** Stable for the element while it lives: `<name>@<n>`. */
  id: string;
  /** The popup's own class (its first that is not a shared `ui-` one), as a selector. */
  name: string;
  box: PopupBox;
  rows: PopupRow[];
};
export type PopupFrame = {
  /** Index among the recorded frames. */
  index: number;
  /** ms since the first recorded frame. */
  t: number;
  popups: PopupShot[];
};
export type PopupRecord = {
  frames: PopupFrame[];
  /** The person's input: when (ms on the same clock as `PopupFrame.t`; negative: before the first
   *  frame) and which popups it was given to. A bare number is input to every popup. */
  inputs: (number | PopupInput)[];
};
export type PopupInput = {
  at: number;
  /** The ids of the popups already drawn when it came (a press: only those it landed in). The
   *  press or key that opens a popup is no input to that popup. */
  popups: string[];
};

/** The default: every visible shared popup that keeps the shared rule (no `data-popup-settle`). */
export const POPUP_STILL_SELECTOR = ".ui-popup:not([data-popup-settle])";

type Sampler = {
  /** Starts recording (again); `selector` defaults to POPUP_STILL_SELECTOR. */
  start(selector?: string): void;
  /** Notes the person's input now. */
  mark(kind: "input"): void;
  /** Frames recorded so far. */
  count(): number;
  /** Stops recording and returns what it recorded. */
  stop(): PopupRecord;
};

declare global {
  interface Window {
    cmuxPopupStill: Sampler;
  }
}

/** The page side; runs in the page, so it closes over nothing. */
function definePopupStill(defaultSelector: string) {
  if (window.cmuxPopupStill) return;
  const rowSelector = '[role="option"], [role^="menuitem"], .acpmux-menu-item';
  const ids = new WeakMap<Element, string>();
  let next = 0;
  let frames: PopupFrame[] = [];
  let inputs: { at: number; popups: string[] }[] = [];
  let recorded = defaultSelector;
  let origin: number | undefined;
  let stopLoop: (() => void) | undefined;
  const now = () => performance.now();
  const round = (value: number) => Math.round(value * 100) / 100;
  const nameOf = (element: Element) => {
    const own = [...element.classList].find((name) => !name.startsWith("ui-"));
    return own ? `.${own}` : ".ui-popup";
  };
  const idOf = (element: Element) => {
    let id = ids.get(element);
    if (!id) ids.set(element, (id = `${nameOf(element)}@${next++}`));
    return id;
  };
  const shoot = (popup: HTMLElement): PopupShot | undefined => {
    const rect = popup.getBoundingClientRect();
    if (!(rect.width > 0 && rect.height > 0)) return undefined;
    const style = getComputedStyle(popup);
    if (style.visibility === "hidden" || style.display === "none") return undefined;
    const seen = new Map<string, number>();
    const rows: PopupRow[] = [];
    for (const row of popup.querySelectorAll<HTMLElement>(rowSelector)) {
      // A nested row (a row's own option) and a row of another popup inside this one count once, there.
      if (row.parentElement?.closest(rowSelector) || row.closest(".ui-popup") !== popup) continue;
      const box = row.getBoundingClientRect();
      if (!(box.height > 0)) continue;
      // Keyed by its label where it has one, so a count or badge that arrives beside it keeps the key.
      const label = row.querySelector(".ui-menu-label, .acpmux-menu-label") ?? row;
      const start = (label.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 24) || "(blank)";
      const repeat = seen.get(start) ?? 0;
      seen.set(start, repeat + 1);
      const first = row.firstElementChild?.getBoundingClientRect();
      const words = document
        .createTreeWalker(row, NodeFilter.SHOW_TEXT, {
          acceptNode: (node) => (node.textContent?.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP),
        })
        .nextNode();
      let text: number | undefined;
      if (words) {
        const range = document.createRange();
        range.selectNodeContents(words);
        const line = range.getClientRects()[0];
        if (line && line.width > 0) text = round(line.left);
      }
      const last = row.lastElementChild?.getBoundingClientRect();
      rows.push({
        key: repeat ? `${start}#${repeat}` : start,
        left: round(box.left),
        height: round(box.height),
        ...(first && first.width > 0 ? { lead: round(first.left) } : {}),
        ...(last && last.width > 0 ? { trail: round(last.right) } : {}),
        ...(text === undefined ? {} : { text }),
      });
    }
    return {
      id: idOf(popup),
      name: nameOf(popup),
      box: { left: round(rect.left), top: round(rect.top), width: round(rect.width), height: round(rect.height) },
      rows,
    };
  };
  // As ui/popupSettle.ts frees a box: a key or a typed letter counts for every open popup, a press
  // only for the popup it lands in. These listeners run before the page's own, so the popups in
  // the document are the ones the person acted on: one their input opens is not there yet.
  const given = (target: EventTarget | null, press: boolean) =>
    [...document.querySelectorAll<HTMLElement>(recorded)]
      .filter((popup) => {
        const rect = popup.getBoundingClientRect();
        if (!(rect.width > 0 && rect.height > 0)) return false;
        return !press || (target instanceof Node && popup.contains(target));
      })
      .map(idOf);
  const onInput = (event: Event) => {
    if (stopLoop) inputs.push({ at: now(), popups: given(event.target, event.type === "pointerdown") });
  };
  for (const kind of ["keydown", "beforeinput", "input", "pointerdown"])
    addEventListener(kind, onInput, { capture: true, passive: true });
  window.cmuxPopupStill = {
    start(selector = defaultSelector) {
      stopLoop?.();
      recorded = selector;
      frames = [];
      inputs = [];
      origin = undefined;
      stopLoop = window.cmuxAfterPaint((frame) => {
        const popups = [...document.querySelectorAll<HTMLElement>(selector)]
          .map(shoot)
          .filter((shot): shot is PopupShot => shot !== undefined);
        if (origin === undefined && popups.length === 0) return;
        origin ??= frame;
        frames.push({ index: frames.length, t: round(frame - origin), popups });
      });
    },
    mark() {
      inputs.push({ at: now(), popups: given(null, false) });
    },
    count: () => frames.length,
    stop() {
      stopLoop?.();
      stopLoop = undefined;
      const zero = origin ?? 0;
      return { frames, inputs: inputs.map((input) => ({ ...input, at: round(input.at - zero) })) };
    },
  };
}

/** Defines `window.cmuxPopupStill` in `page`'s current document and every document it opens from
 *  now on. Needs installPaintedFrames(page) first. `startAtLoad`: each new document starts recording
 *  at once (a popup a gallery play opens is recorded from its first painted frame). */
export async function installPopupStill(page: Page, options: { startAtLoad?: string | true } = {}) {
  await page.addInitScript(definePopupStill, POPUP_STILL_SELECTOR);
  if (options.startAtLoad) {
    const selector = options.startAtLoad === true ? POPUP_STILL_SELECTOR : options.startAtLoad;
    // addInitScript scripts run in order: cmuxAfterPaint and cmuxPopupStill are defined by now.
    await page.addInitScript((chosen) => {
      addEventListener("DOMContentLoaded", () => window.cmuxPopupStill.start(chosen), { once: true });
    }, selector);
  }
  await page.evaluate(definePopupStill, POPUP_STILL_SELECTOR);
}

/** Waits until `frames` more popup frames are recorded than now, then stops and returns the record. */
export async function popupStillFor(page: Page, frames: number): Promise<PopupRecord> {
  const from = await page.evaluate(() => window.cmuxPopupStill.count());
  await page.waitForFunction((target) => window.cmuxPopupStill.count() >= target, from + frames, {
    polling: "raf",
  });
  return page.evaluate(() => window.cmuxPopupStill.stop());
}

export type PopupMoveOptions = {
  /** A popup's first frames, in which it may still size itself (popupSettle.ts STABLE_FRAMES). */
  allowFirstFrames?: number;
  /** A change below this many px is rounding. */
  stillPx?: number;
  /** How long after input a box may change. */
  inputMs?: number;
};

/** What moved in `record` that nobody moved: one human-readable line each, none when it held still. */
export function popupMoves(
  record: PopupRecord | PopupFrame[],
  { allowFirstFrames = 2, stillPx = 0.5, inputMs = POPUP_INPUT_MS }: PopupMoveOptions = {},
): string[] {
  const frames = Array.isArray(record) ? record : record.frames;
  const inputs = Array.isArray(record) ? [] : record.inputs;
  const failures: string[] = [];
  const seen = new Map<string, number>();
  const last = new Map<string, PopupShot>();
  const px = (value: number) => String(Math.round(value * 10) / 10);
  const time = (frame: PopupFrame) => `frame ${frame.index} (t=${Math.round(frame.t)} ms)`;
  for (const frame of frames) {
    for (const shot of frame.popups) {
      const count = (seen.get(shot.id) ?? 0) + 1;
      seen.set(shot.id, count);
      const excused = inputs.some((input) => {
        const at = typeof input === "number" ? input : input.at;
        const mine = typeof input === "number" || input.popups.includes(shot.id);
        return mine && frame.t >= at && frame.t - at <= inputMs;
      });
      const before = last.get(shot.id);
      last.set(shot.id, shot);
      if (!before || count <= allowFirstFrames || excused) continue;
      const moved = (a: number, b: number) => Math.abs(a - b) > stillPx;
      const name = `popup ${shot.name}`;
      const why = `at ${time(frame)} with no input`;
      const { box } = shot;
      const was = before.box;
      if (moved(was.width, box.width))
        failures.push(
          `${name} ${box.width > was.width ? "grew" : "shrank"} ${px(was.width)} -> ${px(box.width)} px wide ${why}`,
        );
      if (moved(was.height, box.height))
        failures.push(
          `${name} ${box.height > was.height ? "grew" : "shrank"} ${px(was.height)} -> ${px(box.height)} px tall ${why}`,
        );
      if (moved(was.left, box.left) || moved(was.top, box.top))
        failures.push(
          `${name} moved from (${px(was.left)}, ${px(was.top)}) to (${px(box.left)}, ${px(box.top)}) ${why}`,
        );
      const rows = new Map(before.rows.map((row) => [row.key, row]));
      for (const row of shot.rows) {
        const old = rows.get(row.key);
        if (!old) continue;
        const what = `${name} row "${row.key}"`;
        if (moved(old.left, row.left))
          failures.push(`${what} moved sideways ${px(old.left)} -> ${px(row.left)} px ${why}`);
        if (moved(old.height, row.height))
          failures.push(
            `${what} ${row.height > old.height ? "grew" : "shrank"} ${px(old.height)} -> ${px(row.height)} px tall ${why}`,
          );
        if (old.lead !== undefined && row.lead !== undefined && moved(old.lead, row.lead))
          failures.push(`${what} leading slot moved ${px(old.lead)} -> ${px(row.lead)} px ${why}`);
        if (old.trail !== undefined && row.trail !== undefined && moved(old.trail, row.trail))
          failures.push(`${what} trailing slot moved ${px(old.trail)} -> ${px(row.trail)} px ${why}`);
        if (old.text !== undefined && row.text !== undefined && moved(old.text, row.text))
          failures.push(`${what} words moved sideways ${px(old.text)} -> ${px(row.text)} px ${why}`);
      }
    }
  }
  return failures;
}

/** The changes of the popup box alone (width, height, place), for a named expected shape. */
export function popupBoxMoves(failures: readonly string[]): string[] {
  return failures.filter((line) => !line.includes(' row "'));
}
