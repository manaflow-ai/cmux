// Every box and point the page sends the App is where it shows under a trackpad pinch, so what the
// App draws from it (a native menu, the toasts' lift) follows the zoomed page (Leo, 2026-11-12:
// "evidently you zoom in and it doesn't really, you know, it doesn't follow"). A Chromium pinch zooms
// the visual viewport only; getBoundingClientRect and clientX stay in the layout.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { installNativeMenu, nativeMenu, type NativeMenuRequest } from "../src/ui/nativeMenu";
import { elementBox } from "../src/agent-session/acpmux/toastAvoidance";

const scope = globalThis as Record<string, unknown>;
let saved: unknown;
let dom: JSDOM | undefined;

afterEach(() => {
  installNativeMenu(null);
  scope.window = saved;
  dom?.window.close();
  dom = undefined;
});

/// A window pinched to 2x, its visual viewport 10 px right and 100 px down into the layout.
function pinched(): Window {
  dom = new JSDOM("<!doctype html><html><body><div id=card></div></body></html>");
  const view = dom.window as unknown as Window;
  Object.defineProperty(view, "visualViewport", {
    value: { scale: 2, offsetLeft: 10, offsetTop: 100 },
    configurable: true,
  });
  saved = scope.window;
  scope.window = view;
  return view;
}

test("a native menu opens where the pointer shows on the pinched page", async () => {
  pinched();
  const heard: NativeMenuRequest[] = [];
  installNativeMenu(async (request) => {
    heard.push(request);
    return { picked: null };
  });
  await nativeMenu()?.({ items: [], point: { x: 60, y: 300 } });
  expect(heard[0]?.point).toEqual({ x: 100, y: 400 });
});

test("the toasts lift above the composer card where it shows on the pinched page", () => {
  const view = pinched();
  const card = view.document.getElementById("card")!;
  card.getBoundingClientRect = () =>
    ({ left: 30, top: 300, right: 230, bottom: 400, width: 200, height: 100 }) as DOMRect;
  expect(elementBox(card)).toEqual({ left: 40, top: 400, right: 440, bottom: 600 });
});
