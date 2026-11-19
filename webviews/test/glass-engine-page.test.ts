// The glass engine in a page (ui/glass/engine/pageGlass.ts): a surface registers, and the engine
// draws it only when it can. With no still of the wallpaper, or no WebGL2, the surface keeps its CSS
// glass: it never carries data-glass-engine and hears drawn = false. Unregistering forgets it.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><body></body>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document, CustomEvent: scope.CustomEvent };

beforeAll(() =>
  Object.assign(scope, { window: dom.window, document: dom.window.document, CustomEvent: dom.window.CustomEvent }),
);
afterAll(() => Object.assign(scope, saved));

test("with no still the surface keeps its own glass; unregister forgets it", async () => {
  const { registerGlassSurface, pageGlassState, GLASS_ENGINE_ATTRIBUTE } =
    await import("../src/ui/glass/engine/pageGlass");
  const doc = dom.window.document;
  const element = doc.createElement("div");
  doc.body.append(element);
  const heard: boolean[] = [];
  const unregister = registerGlassSurface(element, { frost: 4 }, (drawn) => heard.push(drawn));
  expect(pageGlassState(doc)).toEqual({ drawing: false, surfaces: 1, reason: "no-still" });
  expect(element.hasAttribute(GLASS_ENGINE_ATTRIBUTE)).toBe(false);
  expect(heard).not.toContain(true);
  expect(doc.querySelector("canvas[data-cmux-glass-engine]")).toBeNull();
  unregister();
  expect(pageGlassState(doc).surfaces).toBe(0);
});

test("with a still but no WebGL2 the engine stands down and says why", async () => {
  const { registerGlassSurface, pageGlassState } = await import("../src/ui/glass/engine/pageGlass");
  const { installBackdropFallback } = await import("../src/ui/glass/glassState");
  const view = dom.window as unknown as Window & { cmuxTheme?: { backdrop?: (partial: unknown) => void } };
  installBackdropFallback(view);
  view.cmuxTheme?.backdrop?.({
    image: "data:image/png;base64,",
    key: "k1",
    rect: { x: 0, y: 0, width: 800, height: 600 },
  });
  const doc = dom.window.document;
  const element = doc.createElement("div");
  doc.body.append(element);
  const heard: boolean[] = [];
  const unregister = registerGlassSurface(element, undefined, (drawn) => heard.push(drawn));
  // jsdom has no WebGL: create() returns null and no canvas stays in the page.
  expect(pageGlassState(doc).reason).toBe("no-webgl2");
  expect(pageGlassState(doc).drawing).toBe(false);
  expect(heard).not.toContain(true);
  expect(doc.querySelector("canvas[data-cmux-glass-engine]")).toBeNull();
  unregister();
});
