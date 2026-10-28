// l10n-allow-file: test labels only.
// The reasoning menu's opt-in slider (Debug Settings agent.reasoningSlider): the list of levels stays the
// default; with the setting on, the Reasoning section is the stepped slider (EffortTrack), unless
// the model offers a single level. A chat on the agent's own default rests the thumb on the
// recommended level. The slider keeps its stepping keys from the menu, and Escape closes the menu.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { EffortPicker } = await import("../src/agent-session/acpmux/EffortPicker");
const { effortStopCenterX, effortStopShare } = await import("../src/agent-session/acpmux/EffortTrack");
const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
const { readComposerSettings, DEFAULT_COMPOSER } = await import("../src/agent-session/acpmux/composerSettings");

const doc = dom.window.document;
const host = doc.getElementById("root")!;
let root: ReturnType<typeof createRoot> | undefined;

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const levels = [
  { id: "low", name: "Low" },
  { id: "medium", name: "Medium" },
  { id: "high", name: "High", recommended: true },
  { id: "max", name: "Max" },
];
const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));

async function openMenu(props: Partial<Parameters<typeof EffortPicker>[0]> & { picks?: string[] }) {
  const picks = props.picks ?? [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <EffortPicker
        label="effort-test"
        efforts={props.efforts ?? levels}
        current={"current" in props ? props.current : "medium"}
        slider={props.slider}
        sliderStyle={props.sliderStyle}
        speed={props.speed}
        onPick={(value) => picks.push(value)}
      />,
    ),
  );
  await act(async () => void openPicker("effort-test"));
  await settle();
  return picks;
}
const range = () => doc.querySelector<HTMLInputElement>(".acpmux-effort-menu .acpmux-effort-range");
const rows = () =>
  [...doc.querySelectorAll('.acpmux-effort-menu [role="menuitemradio"] .acpmux-menu-label')].map(
    (row) => row.textContent,
  );

test("the composer setting defaults the slider off and reads the host's flag", () => {
  expect(DEFAULT_COMPOSER.reasoningSlider).toBe(false);
  expect(readComposerSettings({}).reasoningSlider).toBe(false);
  expect(readComposerSettings({ reasoningSlider: "yes" }).reasoningSlider).toBe(false);
  expect(readComposerSettings({ reasoningSlider: true }).reasoningSlider).toBe(true);
  expect(DEFAULT_COMPOSER.reasoningSliderStyle).toBe("accent");
  expect(readComposerSettings({}).reasoningSliderStyle).toBe("accent");
  expect(readComposerSettings({ reasoningSliderStyle: "minimal" }).reasoningSliderStyle).toBe("minimal");
  expect(readComposerSettings({ reasoningSliderStyle: "unknown" }).reasoningSliderStyle).toBe("accent");
});

test("the thumb center and every stop share endpoint-inclusive track geometry", () => {
  const left = 24;
  const width = 232;
  const stopCount = 4;
  const stops = Array.from({ length: stopCount }, (_, index) => effortStopCenterX(left, width, index, stopCount));
  expect(stops).toEqual([left, left + width / 3, left + (2 * width) / 3, left + width]);
  for (let index = 0; index < stopCount; index++) {
    expect(effortStopCenterX(left, width, index, stopCount)).toBe(left + width * effortStopShare(index, stopCount));
  }
});

test("off: the reasoning menu is the list of levels, no slider", async () => {
  await openMenu({ slider: false });
  expect(doc.querySelector(".acpmux-effort-menu")).not.toBeNull();
  expect(range()).toBeNull();
  expect(rows()).toEqual(["Low", "Medium", "High", "Max"]);
});

test("on: the Reasoning section is the slider on the current level, and moving it picks", async () => {
  const picks = await openMenu({ slider: true });
  expect(rows()).toEqual([]);
  const input = range()!;
  expect(input).not.toBeNull();
  expect(input.value).toBe("1");
  expect(doc.querySelector(".acpmux-effort-slider-level")?.textContent).toBe("Medium");
  // The menu focuses the slider on open, so its arrow keys step it at once.
  expect(doc.activeElement).toBe(input);
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, "3");
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  expect(picks).toEqual(["max"]);
  // A pick keeps the menu open: the slider is for trying levels.
  expect(doc.querySelector(".acpmux-effort-menu")).not.toBeNull();
});

test("on: the current accent treatment is explicit and minimal is opt-in", async () => {
  await openMenu({ slider: true });
  expect(range()!.closest(".acpmux-effort-track")?.getAttribute("data-slider-style")).toBe("accent");
  act(() => root?.unmount());
  root = undefined;
  await openMenu({ slider: true, sliderStyle: "minimal" });
  expect(range()!.closest(".acpmux-effort-track")?.getAttribute("data-slider-style")).toBe("minimal");
});

test("on: the slider's stepping keys never reach the menu's row navigation", async () => {
  await openMenu({ slider: true });
  const input = range()!;
  for (const key of ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"]) {
    const event = new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
    await act(async () => void input.dispatchEvent(event));
    // Not cancelled: the range input's own default (stepping) still runs.
    expect(event.defaultPrevented).toBe(false);
    expect(doc.querySelector(".acpmux-effort-menu")).not.toBeNull();
  }
});

test("on: Escape on the slider closes the menu back to the chip", async () => {
  await openMenu({ slider: true });
  await act(
    async () =>
      void range()!.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
      ),
  );
  await settle();
  expect(doc.querySelector(".acpmux-effort-menu")).toBeNull();
});

test("on, with a speed section: Down moves from the slider to its rows and Up climbs back", async () => {
  await openMenu({
    slider: true,
    speed: {
      title: "Fast Mode",
      choices: [
        { id: "off", name: "Off" },
        { id: "on", name: "On" },
      ],
      current: "off",
      on: "on",
      onPick() {},
    },
  });
  expect(rows()).toEqual(["Off", "On"]);
  const down = new dom.window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true });
  await act(async () => void range()!.dispatchEvent(down));
  expect(down.defaultPrevented).toBe(true);
  const first = doc.querySelector<HTMLElement>('.acpmux-effort-menu [role="menuitemradio"]')!;
  expect(doc.activeElement).toBe(first);
  await act(
    async () =>
      void first.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true, cancelable: true }),
      ),
  );
  expect(doc.activeElement).toBe(range());
});

test("on, single level: nothing to slide between, so the list shows it", async () => {
  await openMenu({ slider: true, efforts: [{ id: "high", name: "High" }], current: "high" });
  expect(range()).toBeNull();
  expect(rows()).toEqual(["High"]);
});

test("on, current level missing: the thumb rests on the recommended level and nothing is picked", async () => {
  const picks = await openMenu({ slider: true, current: undefined });
  expect(range()!.value).toBe("2");
  expect(doc.querySelector(".acpmux-effort-slider-level")?.textContent).toBe("High");
  expect(picks).toEqual([]);
});

test("on, current level missing and no recommendation: the thumb rests on the first level", async () => {
  const plain = levels.map(({ id, name }) => ({ id, name }));
  await openMenu({ slider: true, efforts: plain, current: "gone" });
  expect(range()!.value).toBe("0");
  expect(doc.querySelector(".acpmux-effort-slider-level")?.textContent).toBe("Low");
});

const key = (target: Element, name: string) =>
  act(
    async () =>
      void target.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }),
      ),
  );

test("on, current level missing: a click on the resting thumb picks the recommended level once", async () => {
  const picks = await openMenu({ slider: true, current: undefined });
  await act(async () => void range()!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
  await act(async () => void range()!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
  expect(picks).toEqual(["high"]);
});

test("on, current level missing: a drag's closing click does not resend the level it picked", async () => {
  const picks = await openMenu({ slider: true, current: undefined });
  const input = range()!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, "3");
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () => void input.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
  expect(picks).toEqual(["max"]);
});

test("on, current level set: a click on the thumb sends nothing", async () => {
  const picks = await openMenu({ slider: true });
  await act(async () => void range()!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
  expect(picks).toEqual([]);
});

test("on, current level missing: Enter picks the resting level and closes the menu", async () => {
  const picks = await openMenu({ slider: true, current: undefined });
  await key(range()!, "Enter");
  await settle();
  expect(picks).toEqual(["high"]);
  expect(doc.querySelector(".acpmux-effort-menu")).toBeNull();
});

test("on, current level set: Enter closes the menu without a pick", async () => {
  const picks = await openMenu({ slider: true });
  await key(range()!, "Enter");
  await settle();
  expect(picks).toEqual([]);
  expect(doc.querySelector(".acpmux-effort-menu")).toBeNull();
});

test("on: the slider is a group the menu names Reasoning", async () => {
  await openMenu({ slider: true });
  const group = range()!.closest("fieldset")!;
  expect(group).not.toBeNull();
  expect(doc.getElementById(group.getAttribute("aria-labelledby")!)?.textContent).toBe("Reasoning");
});
