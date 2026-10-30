import { afterEach, expect, test } from "bun:test";
import { MEDIA_PREVIEW_DWELL, HoverIntent, type HoverClock } from "./hoverIntent";
import { mediaPreviewAllowed } from "./mediaPreviewPolicy";

const scope = globalThis as Record<string, unknown>;
const savedWindow = scope.window;

afterEach(() => {
  if (savedWindow === undefined) delete scope.window;
  else scope.window = savedWindow;
});

function root(data: Record<string, string> = {}) {
  return { dataset: data } as unknown as HTMLElement;
}

class FakeClock implements HoverClock {
  now = 0;
  private next = 1;
  private timers: Array<{ at: number; id: number; run: () => void }> = [];

  set = (run: () => void, ms: number) => {
    const id = this.next++;
    this.timers.push({ at: this.now + ms, id, run });
    return id;
  };

  clear = (id: unknown) => {
    this.timers = this.timers.filter((timer) => timer.id !== id);
  };

  advance(ms: number) {
    const end = this.now + ms;
    for (;;) {
      const timer = this.timers.filter((candidate) => candidate.at <= end).sort((a, b) => a.at - b.at)[0];
      if (!timer) break;
      this.timers = this.timers.filter((candidate) => candidate !== timer);
      this.now = timer.at;
      timer.run();
    }
    this.now = end;
  }
}

test("allows hover previews when motion is available", () => {
  expect(mediaPreviewAllowed(root())).toBe(true);
});

test("blocks previews for app and system motion policies", () => {
  expect(mediaPreviewAllowed(root({ agentMotion: "off" }))).toBe(false);
  expect(mediaPreviewAllowed(root({ agentMotion: "reduced" }))).toBe(false);
  expect(mediaPreviewAllowed(root({ cmuxMotion: "off" }))).toBe(false);
  expect(mediaPreviewAllowed(root({ cmuxMotion: "reduced" }))).toBe(false);
  expect(mediaPreviewAllowed(root({ statusIndicators: "static" }))).toBe(false);

  scope.window = { matchMedia: () => ({ matches: true }) };
  expect(mediaPreviewAllowed(root())).toBe(false);
});

test("waits for the shared media dwell before showing a preview", () => {
  const clock = new FakeClock();
  const shown: boolean[] = [];
  const intent = new HoverIntent<boolean>({
    clock,
    delay: MEDIA_PREVIEW_DWELL,
    show: (target) => shown.push(target),
    hide: () => shown.push(false),
  });

  intent.hover(true);
  clock.advance(MEDIA_PREVIEW_DWELL - 1);
  expect(shown).toEqual([]);
  clock.advance(1);
  expect(shown).toEqual([true]);
  intent.hover(null);
  expect(shown).toEqual([true, false]);
});
