// The Theme section (P3, P4): the preview draws the theme in effect, the picker writes
// appearance.theme, Match System Appearance writes a light/dark pair, a narrower scope's theme
// shows inline with a Reset that clears that level, and the app theme is the host's `app` level.
import { afterAll, afterEach, expect, jest, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, fire, ops, renderPage, run, settle } = await import("./testing");
const { act } = await import("react");

let page: Rendered | null = null;
afterEach(() => {
  jest.useRealTimers();
  page?.unmount();
  page = null;
});

/// Yields to the page until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await settle();
  }
}

const theme = (page: Rendered) => page.container.querySelector<HTMLElement>('[data-card="theme"]')!;

test("the preview shows the configured theme and its derived contrast", async () => {
  page = await renderPage({ path: "/settings/theme", mock: { values: { "appearance.theme": "Dracula" } } });
  expect(theme(page).querySelector("[data-theme-preview]")?.getAttribute("data-theme-preview")).toBe("Dracula");
  expect(theme(page).querySelector("[data-contrast]")?.textContent).toMatch(/text \d+(\.\d)?:1/);
  expect(ops(page.provider, "cmux.settings.theme.colors").length).toBe(1);
});

test("an override in a narrower scope shows inline, and Reset clears that level", async () => {
  page = await renderPage({ path: "/settings/theme" });
  const note = theme(page).querySelector<HTMLElement>('[data-override="workspace"]')!;
  expect(note.textContent).toContain("Overridden in this workspace by Dracula");
  expect(page.container.querySelector('input[name="theme-level"]')).toBeNull();
  await click(note.querySelector("button")!);
  expect(ops(page.provider, "cmux.settings.theme.set")).toEqual([{ level: "workspace", spec: null }]);
  expect(theme(page).querySelector('[data-override="workspace"]')).toBeNull();
});

test("picking a theme writes appearance.theme; Match System Appearance writes a pair", async () => {
  page = await renderPage({ path: "/settings/theme" });
  await run(() => page!.store.set("appearance.theme", "Tokyo Night"));
  expect(theme(page).querySelector("[data-theme-picker]")?.textContent).toContain("Tokyo Night");
  await click(theme(page).querySelector('[data-theme-row="match"] [role=switch]')!);
  const writes = ops(page.provider, "cmux.settings.set");
  expect(writes.at(-1)).toEqual({ key: "appearance.theme", value: expect.stringMatching(/^light:.+,dark:.+$/) });
  expect(theme(page).querySelectorAll("[data-theme-picker]").length).toBe(3);
  await click(theme(page).querySelector('[data-theme-row="match"] [role=switch]')!);
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({
    key: "appearance.theme",
    value: expect.not.stringContaining(":"),
  });
});

test("the app theme (appearance.appTheme) matches the terminal theme until it names one", async () => {
  page = await renderPage({ path: "/settings/theme" });
  const app = () => theme(page!).querySelector<HTMLElement>('[data-theme-row="app"]')!;
  expect(app().textContent).toContain("Match Terminal Theme");
  await run(() => page!.store.set("appearance.appTheme", "Gruvbox Dark"));
  expect(app().textContent).toContain("Gruvbox Dark");
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({ key: "appearance.appTheme", value: "Gruvbox Dark" });
  await run(() => page!.store.reset("appearance.appTheme"));
  expect(app().textContent).toContain("Match Terminal Theme");
});

test("an unset theme previews the Ghostty config's own colors from the host", async () => {
  page = await renderPage({ path: "/settings/theme" });
  const preview = theme(page).querySelector("[data-theme-preview]")!;
  expect(preview.getAttribute("data-theme-preview")).toBe("Use Ghostty Config");
  // The mock's config is Apple System Colors (#1e1e1e); the preview draws its background.
  expect(preview.querySelector("rect")?.getAttribute("fill")).toBe("#1e1e1e");
});

test("a theme shows as a round ball: its background, its text color and its six hues, the accent hue largest", async () => {
  page = await renderPage({ path: "/settings/theme", mock: { values: { "appearance.theme": "Dracula" } } });
  const ball = theme(page).querySelector<SVGElement>("[data-theme-picker] [data-theme-ball]")!;
  expect(ball.getAttribute("data-theme-ball")).toBe("Dracula");
  // Only circles: no rounded rectangles or pills.
  expect(ball.querySelectorAll("rect, path, ellipse").length).toBe(0);
  const fill = (selector: string) => ball.querySelector(selector)?.getAttribute("fill");
  expect(fill('[data-ball="surface"]')).toBe("#282a36");
  expect(fill('[data-ball="text"]')).toBe("#f8f8f2");
  const dracula = [
    ["#ff5555", "#ff6e6e"],
    ["#50fa7b", "#69ff94"],
    ["#f1fa8c", "#ffffa5"],
    ["#bd93f9", "#d6acff"],
    ["#ff79c6", "#ff92df"],
    ["#8be9fd", "#a4ffff"],
  ];
  const ring = [...ball.querySelectorAll("[data-ball-hue]")];
  expect(ring.map((dot) => dot.getAttribute("data-ball-hue"))).toEqual(["1", "2", "3", "4", "5", "6"]);
  ring.forEach((dot, index) => expect(dracula[index]).toContain(dot.getAttribute("fill")!));
  // Dracula's `theme` accent is its magenta: that dot is the largest of the ring.
  const accent = ball.querySelector("[data-ball-accent]")!;
  expect(accent.getAttribute("data-ball-hue")).toBe("5");
  const radius = (dot: Element) => Number(dot.getAttribute("r"));
  for (const dot of ring) if (dot !== accent) expect(radius(accent)).toBeGreaterThan(radius(dot));
});

test("a theme previews live in the app before it is picked: hover or arrows, right-click pins it, Escape reverts", async () => {
  page = await renderPage({ path: "/settings/theme" });
  await click(theme(page).querySelector('[data-theme-row="app"] [data-theme-picker]')!);
  const option = (name: string) => document.querySelector<HTMLElement>(`[data-theme-option="${name}"]`)!;
  const previews = () => ops(page!.provider, "cmux.settings.preview");
  // Right-click a theme: the app shows it, without a write, and it stays while the pointer moves on.
  await fire(option("Dracula"), "contextmenu");
  expect(previews().at(-1)).toEqual({ key: "appearance.appTheme", value: "Dracula" });
  expect(option("Dracula").closest("[data-previewing]")).not.toBeNull();
  expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
  // Escape reverts: the preview ends and nothing was written.
  await fire(document.querySelector<HTMLElement>(".theme-search")!, "keydown", { key: "Escape" });
  expect(ops(page.provider, "cmux.settings.preview.end").length).toBeGreaterThan(0);
  expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
});

test("a late theme save cannot end a newer preview after the picker reopens", async () => {
  page = await renderPage({ path: "/settings/theme" });
  let resolveSave!: () => void;
  page.store.set = (() =>
    new Promise<void>((resolve) => (resolveSave = resolve))) as unknown as Rendered["store"]["set"];
  const button = theme(page).querySelector('[data-theme-row="app"] [data-theme-picker]')!;
  await click(button);
  const search = document.querySelector<HTMLElement>(".theme-search")!;
  await fire(search, "keydown", { key: "ArrowDown" });
  await fire(search, "keydown", { key: "ArrowDown" });
  await fire(search, "keydown", { key: "Enter" });
  await click(button);
  const reopened = document.querySelector<HTMLElement>(".theme-search")!;
  await fire(reopened, "keydown", { key: "ArrowDown" });
  await fire(reopened, "keydown", { key: "ArrowDown" });
  expect(ops(page.provider, "cmux.settings.preview").length).toBe(2);
  const endsBeforeSave = ops(page.provider, "cmux.settings.preview.end").length;
  resolveSave();
  await settle();
  expect(ops(page.provider, "cmux.settings.preview.end").length).toBe(endsBeforeSave);
});

test("a late cleanup for one key cannot end the newer preview of another: the host holds one preview", async () => {
  page = await renderPage({ path: "/settings/theme" });
  const terminal = {};
  const app = {};
  page.store.preview("appearance.theme", "Dracula", terminal);
  page.store.preview("appearance.appTheme", "Nord", app);
  await settle();
  page.store.previewEnd("appearance.theme", terminal);
  await settle();
  expect(ops(page.provider, "cmux.settings.preview.end")).toEqual([]);
  page.store.previewEnd("appearance.appTheme", app);
  await settle();
  expect(ops(page.provider, "cmux.settings.preview.end")).toEqual([{ key: "appearance.appTheme" }]);
});

test("a late theme save leaves the pointer's pending preview in the reopened picker alone", async () => {
  const { DWELL_MS } = await import("./components/ThemePicker");
  page = await renderPage({ path: "/settings/theme" });
  let resolveSave!: () => void;
  page.store.set = (() =>
    new Promise<void>((resolve) => (resolveSave = resolve))) as unknown as Rendered["store"]["set"];
  const button = theme(page).querySelector('[data-theme-row="app"] [data-theme-picker]')!;
  await click(button);
  const search = document.querySelector<HTMLElement>(".theme-search")!;
  await fire(search, "keydown", { key: "ArrowDown" });
  await fire(search, "keydown", { key: "ArrowDown" });
  await fire(search, "keydown", { key: "Enter" });
  await click(button);
  const row = (name: string) => document.querySelector<HTMLElement>(`[data-theme-option="${name}"]`)!.closest("li")!;
  const names = [...document.querySelectorAll<HTMLElement>("[data-theme-option]")].map((el) =>
    el.getAttribute("data-theme-option")!,
  );
  const hovered = names.at(-1)!;
  const previews = () => ops(page!.provider, "cmux.settings.preview");
  const before = previews().length;
  jest.useFakeTimers();
  await act(async () => {
    for (const type of ["pointerenter", "pointermove", "mousemove", "mouseenter"])
      row(hovered).dispatchEvent(new window.MouseEvent(type, { bubbles: type.endsWith("move"), cancelable: true }));
  });
  resolveSave();
  await act(async () => {});
  await act(async () => void jest.advanceTimersByTime(DWELL_MS));
  await act(async () => {});
  jest.useRealTimers();
  expect(previews().slice(before)).toEqual([{ key: "appearance.appTheme", value: hovered }]);
});

test("a pointer passing over themes previews nothing until it rests; the arrow keys preview at once", async () => {
  const { DWELL_MS } = await import("./components/ThemePicker");
  page = await renderPage({ path: "/settings/theme" });
  await click(theme(page).querySelector('[data-theme-row="app"] [data-theme-picker]')!);
  const row = (name: string) => document.querySelector<HTMLElement>(`[data-theme-option="${name}"]`)!.closest("li")!;
  const previews = () => ops(page!.provider, "cmux.settings.preview");
  const pointer = (element: Element) =>
    act(async () => {
      for (const type of ["pointerenter", "pointermove", "mousemove", "mouseenter"])
        element.dispatchEvent(new window.MouseEvent(type, { bubbles: type.endsWith("move"), cancelable: true }));
    });
  const names = [...document.querySelectorAll<HTMLElement>("[data-theme-option]")]
    .slice(0, 4)
    .map((el) => el.getAttribute("data-theme-option")!);
  const before = previews().length;
  // A sweep down the list: the rows highlight, but the app shows none of them. The dwell runs on a
  // fake clock: it is the behavior, so a slow runner's late wake-ups must not decide it. The mock
  // transport answers in microtasks, which an empty act drains.
  jest.useFakeTimers();
  for (const name of names) await pointer(row(name));
  await act(async () => void jest.advanceTimersByTime(DWELL_MS - 1));
  await act(async () => {});
  expect(previews().length).toBe(before);
  // The pointer rests on the last row: that one previews, once.
  await act(async () => void jest.advanceTimersByTime(1));
  await act(async () => {});
  jest.useRealTimers();
  const rested = previews().slice(before);
  expect(rested.length).toBe(1);
  // The arrow keys preview the row they land on with no wait.
  const search = document.querySelector<HTMLElement>(".theme-search")!;
  const keyed = previews().length;
  await fire(search, "keydown", { key: "ArrowDown" });
  expect(previews().length).toBe(keyed + 1);
  await fire(search, "keydown", { key: "Escape" });
});

test("a theme with color edits reads as custom and previews its edited colors", async () => {
  page = await renderPage({
    path: "/settings/theme",
    mock: {
      values: {
        "appearance.theme": "Dracula",
        "appearance.themeEdits": { "Dracula/background": "#101010", "Gruvbox Dark/4": "#123456" },
      },
    },
  });
  expect(theme(page).querySelector("[data-theme-picker]")?.textContent).toContain("Dracula (custom)");
  // The preview draws the edited background; the theme's other colors stay its own.
  expect(theme(page).querySelector("[data-theme-preview] rect")?.getAttribute("fill")).toBe("#101010");
  await click(theme(page).querySelector("[data-theme-picker]")!);
  const name = (theme: string) =>
    document.querySelector(`[data-theme-option="${theme}"] .theme-option-name`)?.textContent ?? "";
  expect(name("Gruvbox Dark")).toBe("Gruvbox Dark (custom)");
  expect(name("Tokyo Night")).toBe("Tokyo Night");
  // The edits never become a setting row of their own.
  expect(page.container.querySelector('[data-row-key="appearance.themeEdits"]')).toBeNull();
});

test("each theme color is editable: sliders and snaps preview live, Done keeps the edit, Escape reverts", async () => {
  page = await renderPage({
    path: "/settings/theme",
    mock: { values: { "appearance.theme": "Dracula", "appearance.themeEdits": { "Dracula/1": "#ff0000" } } },
  });
  const token = (name: string) => theme(page!).querySelector<HTMLButtonElement>(`[data-token="${name}"]`)!;
  const tuner = () => document.querySelector<HTMLElement>("[data-token-tuner]");
  const edits = () =>
    ops(page!.provider, "cmux.settings.set").filter((op) => (op as { key: string }).key === "appearance.themeEdits");
  expect(token("1").hasAttribute("data-edited")).toBe(true);
  expect(token("4").hasAttribute("data-edited")).toBe(false);

  // A hue drag previews the edited theme live, without a write.
  await click(token("4"));
  const hue = tuner()!.querySelectorAll<HTMLInputElement>('input[type="range"]')[2]!;
  await changeValue(hue, "30");
  // The live preview goes out at most every 80 ms.
  await until(
    () =>
      ops(page!.provider, "cmux.settings.preview").some(
        (op) => (op as { key: string }).key === "appearance.themeEdits",
      ),
    "the hue's live preview",
  );
  const preview = ops(page.provider, "cmux.settings.preview").at(-1) as { key: string; value: Record<string, string> };
  expect(preview.key).toBe("appearance.themeEdits");
  expect(preview.value["Dracula/1"]).toBe("#ff0000");
  expect(preview.value["Dracula/4"]).toMatch(/^#[0-9a-f]{6}$/);
  expect(edits()).toEqual([]);
  // Escape reverts: the preview ends and nothing is written.
  await fire(tuner()!.querySelector("input")!, "keydown", { key: "Escape" });
  expect(tuner()).toBeNull();
  expect(edits()).toEqual([]);
  expect(ops(page.provider, "cmux.settings.preview.end").length).toBeGreaterThan(0);

  // A snap color applies at once, and Done keeps it as the theme's edit (the original theme never changes).
  await click(token("4"));
  const snap = tuner()!.querySelector<HTMLButtonElement>("[data-snap]")!;
  const snapped = snap.getAttribute("data-snap")!;
  await click(snap);
  expect(tuner()!.querySelector<HTMLInputElement>("input")!.value).toBe(snapped);
  await click([...tuner()!.querySelectorAll("button")].at(-1)!);
  expect(edits().at(-1)).toEqual({
    key: "appearance.themeEdits",
    value: { "Dracula/1": "#ff0000", "Dracula/4": snapped },
  });
});

test("a theme color below its contrast floor says so and Raise Contrast lifts it; Reset drops the edit", async () => {
  page = await renderPage({
    path: "/settings/theme",
    mock: { values: { "appearance.theme": "Dracula", "appearance.themeEdits": { "Dracula/1": "#ff0000" } } },
  });
  const tuner = () => document.querySelector<HTMLElement>("[data-token-tuner]");
  await click(theme(page).querySelector('[data-token="foreground"]')!);
  // Dracula's background is #282a36: a foreground this close fails 4.5:1.
  await changeValue(tuner()!.querySelector<HTMLInputElement>("input")!, "#30323e");
  const readout = () => tuner()!.querySelector<HTMLElement>(".token-tuner-contrast")!;
  expect(readout().hasAttribute("data-contrast-low")).toBe(true);
  await click(readout().querySelector("button")!);
  expect(readout().hasAttribute("data-contrast-low")).toBe(false);
  expect(Number(readout().textContent!.match(/([\d.]+):1/)![1])).toBeGreaterThanOrEqual(4.5);
  await fire(tuner()!.querySelector("input")!, "keydown", { key: "Escape" });

  // Reset on an edited color removes its entry; with none left the key resets.
  await click(theme(page).querySelector('[data-token="1"]')!);
  const reset = [...tuner()!.querySelectorAll("button")].find((button) => button.textContent === "Reset")!;
  await click(reset);
  expect(ops(page.provider, "cmux.settings.reset").at(-1)).toEqual({ key: "appearance.themeEdits" });
});

test("a light/dark pair shows the side for the Mac's appearance, not the window's", async () => {
  // A dark App Theme makes the page's window dark (prefers-color-scheme: dark) while macOS is light:
  // the terminals use the pair's light side, so Settings must show and edit that side.
  const previous = window.matchMedia;
  window.matchMedia = ((query: string) =>
    ({
      matches: query.includes("dark"),
      media: query,
      addEventListener() {},
      removeEventListener() {},
    }) as unknown as MediaQueryList) as typeof window.matchMedia;
  try {
    page = await renderPage({
      path: "/settings/theme",
      mock: { values: { "appearance.theme": "light:GitHub Light,dark:Dracula" } },
      setup: (provider) =>
        provider.setHost({ ...provider.host, theme: { ...provider.host.theme!, system_scheme: "light" } }),
    });
    expect(theme(page).querySelector("[data-theme-preview]")?.getAttribute("data-theme-preview")).toBe("GitHub Light");
    // Match System Appearance off keeps the side in effect on this Mac.
    await click(theme(page).querySelector('[data-theme-row="match"] [role=switch]')!);
    expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({ key: "appearance.theme", value: "GitHub Light" });
  } finally {
    window.matchMedia = previous;
  }
});

test("with an App Theme set, a space or workspace theme says it replaces the App Theme in its window too", async () => {
  // A workspace theme colors its window's chrome (the room shows its workspace's colors), App Theme
  // or not: the note must not read as if only the terminal theme gave way.
  page = await renderPage({ path: "/settings/theme", mock: { values: { "appearance.appTheme": "GitHub Light" } } });
  const note = theme(page).querySelector<HTMLElement>('[data-override="workspace"]')!;
  expect(note.textContent).toContain("Overridden in this workspace by Dracula, App Theme included");
  await run(() => page!.store.reset("appearance.appTheme"));
  expect(theme(page).querySelector('[data-override="workspace"]')?.textContent).not.toContain("App Theme included");
});
