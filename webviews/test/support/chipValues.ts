// What the composer's picker chips say on every painted frame, so a test can tell that a pick
// changed the visible value once, straight to the picked value, and that nothing changed it later.
import type { Page } from "playwright";
import { MODEL_PICKER } from "../../src/agent-session/acpmux/composerSelectors";

/** The visible values: the model chip (with its effort), the access chip. */
export type ChipValues = { model: string; access: string };
export type ValueFrame = { t: number } & ChipValues;

declare global {
  interface Window {
    cmuxChipValues?: { frames: ValueFrame[]; all: ValueFrame[]; stop?: () => void };
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
      const store = (window.cmuxChipValues = { frames: [], all: [] } as NonNullable<Window["cmuxChipValues"]>);
      store.stop = window.cmuxAfterPaint((t) => {
        const value = { t, model: text(model), access: text(access) };
        const last = store.frames.at(-1);
        if (!last || last.model !== value.model || last.access !== value.access) {
          store.frames.push(value);
          store.all.push(value);
        }
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

/** One frame on the pane's acpmux socket, as the page saw it: what it says about the chips' values. */
export type WireEvent = { t: number; dir: "out" | "in"; what: string };

declare global {
  interface Window {
    cmuxWire?: WireEvent[];
  }
}

/**
 * Records, before the page loads, each frame on its acpmux socket that bears on the chips: the
 * picks it sends (session/new, set_model, set_mode, set_config_option, prompt) and the mode,
 * model and effort each frame it receives names, on the page's clock, to read beside the chips.
 */
export async function installWireLog(page: Page): Promise<void> {
  await page.addInitScript(() => {
    const log: WireEvent[] = (window.cmuxWire = []);
    const picks = /^session\/(new|set_model|set_mode|set_config_option|prompt)$/;
    const named = (text: string) => {
      const found: string[] = [];
      for (const [key, pattern] of [
        ["mode", /"currentModeId":"([^"]+)"/],
        ["model", /"(?:currentModelId|model)":"([^"]+)"/],
        ["effort", /"id":"(?:reasoning_effort|effort)"[^}]*?"currentValue":"([^"]+)"/],
      ] as const) {
        const match = pattern.exec(text);
        if (match) found.push(`${key}=${match[1]}`);
      }
      return found.join(" ");
    };
    const Native = window.WebSocket;
    const send = Native.prototype.send;
    Native.prototype.send = function (this: WebSocket, data: any) {
      if (typeof data === "string")
        try {
          const frame = JSON.parse(data);
          if (picks.test(frame.method ?? ""))
            log.push({
              t: performance.now(),
              dir: "out",
              what: `${frame.id} ${frame.method} ${JSON.stringify(frame.params ?? {})
                .replace(/"prompt":\[.*?\]/, '"prompt":[...]')
                .slice(0, 200)}`,
            });
        } catch {}
      return send.call(this, data);
    };
    const add = Native.prototype.addEventListener;
    const note = (event: MessageEvent) => {
      if (typeof event.data !== "string") return;
      const what = named(event.data);
      if (!what) return;
      const id = /^\{"id":([^,]+),/.exec(event.data)?.[1];
      const method = /"method":"([^"]+)"/.exec(event.data)?.[1];
      log.push({ t: performance.now(), dir: "in", what: `${id ? `#${id}` : (method ?? "?")} ${what}` });
    };
    Native.prototype.addEventListener = function (this: WebSocket, type: string, listener: any, options?: any) {
      if (type === "message" && !(this as any).cmuxWired) {
        (this as any).cmuxWired = true;
        add.call(this, "message", note as any);
      }
      return add.call(this, type, listener, options);
    };
    const onmessage = Object.getOwnPropertyDescriptor(Native.prototype, "onmessage");
    if (onmessage?.set)
      Object.defineProperty(Native.prototype, "onmessage", {
        ...onmessage,
        set(this: WebSocket, listener: any) {
          if (!(this as any).cmuxWired) {
            (this as any).cmuxWired = true;
            add.call(this, "message", note as any);
          }
          onmessage.set!.call(this, listener);
        },
      });
  });
}

/** The chips' changes and the wire events since `from` (page clock), one line each, in order. */
export async function timeline(page: Page, from = 0): Promise<string[]> {
  return page.evaluate((from) => {
    const rows: { t: number; line: string }[] = [];
    for (const frame of window.cmuxChipValues?.all ?? [])
      if (frame.t >= from) rows.push({ t: frame.t, line: `chips: ${frame.model} | ${frame.access}` });
    for (const event of window.cmuxWire ?? [])
      if (event.t >= from) rows.push({ t: event.t, line: `${event.dir === "out" ? "->" : "<-"} ${event.what}` });
    rows.sort((a, b) => a.t - b.t);
    return rows.map((row) => `${Math.round(row.t - from)}ms ${row.line}`);
  }, from);
}
