// What the composer's picker chips say on every painted frame, so a test can tell that a pick
// changed the visible value once, straight to the picked value, and that nothing changed it later.
import type { Page } from "playwright";
import { MODEL_PICKER } from "../../src/agent-session/acpmux/composerSelectors";

/** The visible values: the model chip (with its effort), the access chip. */
export type ChipValues = { model: string; access: string };
export type ValueFrame = { t: number } & ChipValues;

declare global {
  interface Window {
    cmuxChipValues?: { frames: ValueFrame[]; stop?: () => void };
  }
}

const ACCESS = ".acpmux-access-trigger";

/** Reads the chips' text now. */
export async function chipValues(page: Page): Promise<ChipValues> {
  return page.evaluate(
    ({ model, access }) => {
      const text = (selector: string) =>
        (document.querySelector(selector)?.textContent ?? "").replace(/\s+/g, " ").trim();
      return { model: text(model), access: text(access) };
    },
    { model: MODEL_PICKER, access: ACCESS },
  );
}

/** Starts sampling the chips on every painted frame (after installPaintedFrames); a new start replaces it. */
export async function startValueSampler(page: Page): Promise<void> {
  await page.evaluate(
    ({ model, access }) => {
      window.cmuxChipValues?.stop?.();
      const text = (selector: string) =>
        (document.querySelector(selector)?.textContent ?? "").replace(/\s+/g, " ").trim();
      const store = (window.cmuxChipValues = { frames: [] } as NonNullable<Window["cmuxChipValues"]>);
      store.stop = window.cmuxAfterPaint((t) => {
        const value = { t, model: text(model), access: text(access) };
        const last = store.frames.at(-1);
        if (!last || last.model !== value.model || last.access !== value.access) store.frames.push(value);
      });
    },
    { model: MODEL_PICKER, access: ACCESS },
  );
}

/** The distinct values the chips showed since the last take, in order (the last one starts the next window). */
export async function takeValues(page: Page): Promise<ValueFrame[]> {
  return page.evaluate(() => {
    const store = window.cmuxChipValues;
    if (!store) return [];
    const frames = store.frames.splice(0);
    if (frames.length) store.frames.push(frames.at(-1)!);
    return frames;
  });
}
