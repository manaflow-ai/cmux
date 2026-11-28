// Floating UI's React bindings, under every Base UI tooltip, menu and popover, decide once, when
// they first load, whether to run layout effects: they check for a global `document`. Here Base UI
// loads before the file installs jsdom, as in any file with static src/ui imports, and as an earlier
// file's imports do for every later file in one `bun test` process. Without test/preload.ts loading
// @floating-ui/react-dom with a document, the positioner never positions and keeps Base UI's
// `opacity: 0` (session-info-subagent-card-stays failed so behind session-info-motion, and passed
// alone). Alone, this file is that order every time.
import { afterAll, expect, test } from "bun:test";
import { Tooltip } from "@base-ui/react/tooltip";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const loadedWithoutDocument = !("document" in globalThis);
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const container = dom.window.document.getElementById("root")!;
const root = createRoot(container);
afterAll(async () => {
  act(() => root.unmount());
  await teardownDom(saved, { window: dom.window, scope });
});

test("a Base UI tooltip loaded before any document still positions when it opens", async () => {
  expect(loadedWithoutDocument).toBe(true);
  await act(async () =>
    root.render(
      <Tooltip.Provider>
        <Tooltip.Root open>
          <Tooltip.Trigger render={<button type="button">?</button>} />
          <Tooltip.Portal container={container}>
            <Tooltip.Positioner className="positioner">
              <Tooltip.Popup>tip</Tooltip.Popup>
            </Tooltip.Positioner>
          </Tooltip.Portal>
        </Tooltip.Root>
      </Tooltip.Provider>,
    ),
  );
  const positioner = container.querySelector<HTMLElement>(".positioner");
  expect(positioner).toBeTruthy();
  // Base UI draws the positioner at `opacity: 0` until Floating UI reports a position.
  expect(positioner!.style.opacity).toBe("");
});
