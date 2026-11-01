import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { AppearanceHistory, diff, HISTORY_LIMIT, type KeyState } from "./appearanceHistory";
import { activePreset, APPEARANCE_PRESETS } from "./appearancePresets";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, ops, renderPage, run } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const setting = (key: string, value: unknown, customized = true): KeyState => ({
  kind: "setting",
  key,
  value,
  customized,
});

describe("the undo stack (model)", () => {
  test("undo returns the before states last change first, redo the after states", () => {
    const history = new AppearanceHistory();
    const before = [setting("a", null, false), setting("b", 1)];
    const after = [setting("a", "x"), setting("b", 2)];
    expect(history.record({ label: "A → x", changes: diff(before, after) })).toBe(true);
    expect(history.canUndo).toBe(true);
    expect(history.canRedo).toBe(false);
    expect(history.nextUndo?.label).toBe("A → x");

    const undo = history.takeUndo()!;
    expect(undo.apply).toEqual([setting("b", 1), setting("a", null, false)]);
    expect(history.canUndo).toBe(false);
    expect(history.nextRedo?.label).toBe("A → x");

    const redo = history.takeRedo()!;
    expect(redo.apply).toEqual([setting("a", "x"), setting("b", 2)]);
    expect(history.canUndo).toBe(true);
    expect(history.canRedo).toBe(false);
  });

  test("a step that changed nothing is not recorded; two unset states are the same", () => {
    const history = new AppearanceHistory();
    expect(diff([setting("a", null, false)], [setting("a", "ignored", false)])).toEqual([]);
    expect(history.record({ label: "nothing", changes: [] })).toBe(false);
    expect(history.canUndo).toBe(false);
  });

  test("a new step clears Redo, and the stack keeps its last steps", () => {
    const history = new AppearanceHistory();
    const step = (n: number) => ({ label: String(n), changes: diff([setting("a", n - 1)], [setting("a", n)]) });
    history.record(step(1));
    history.takeUndo();
    expect(history.canRedo).toBe(true);
    history.record(step(2));
    expect(history.canRedo).toBe(false);
    for (let n = 3; n < HISTORY_LIMIT + 10; n += 1) history.record(step(n));
    let count = 0;
    while (history.takeUndo()) count += 1;
    expect(count).toBe(HISTORY_LIMIT);
  });

  test("a failed undo puts the step back on the undo side", () => {
    const history = new AppearanceHistory();
    history.record({ label: "x", changes: diff([setting("a", 1)], [setting("a", 2)]) });
    const step = history.takeUndo()!;
    history.restore("undo", step.entry);
    expect(history.nextUndo).toBe(step.entry);
    expect(history.canRedo).toBe(false);
  });
});

describe("Appearance's floating Undo, Redo and Reset", () => {
  const bar = () => page!.container.querySelector<HTMLElement>("[data-appearance-bar]")!;
  const undoButton = () => bar().querySelector<HTMLButtonElement>("[data-undo]")!;
  const redoButton = () => bar().querySelector<HTMLButtonElement>("[data-redo]")!;

  test("shows on Appearance with Undo and Redo disabled until something changed", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    expect(bar()).not.toBeNull();
    expect(undoButton().disabled).toBe(true);
    expect(redoButton().disabled).toBe(true);
    page.unmount();
    page = await renderPage({ path: "/settings/general" });
    expect(page.container.querySelector("[data-appearance-bar]")).toBeNull();
  });

  test("picking a background is undoable and redoable, and the buttons name the step", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    const tile = page.container.querySelector<HTMLButtonElement>('.backdrop-tile[aria-label="Shuffle Paintings"]')!;
    await click(tile);
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "appearance.background", value: "daily" }]);
    expect(undoButton().disabled).toBe(false);
    expect(undoButton().getAttribute("aria-label")).toBe("Undo: Background → Shuffle Paintings");

    await click(undoButton());
    expect(ops(page.provider, "cmux.settings.reset")).toEqual([{ key: "appearance.background" }]);
    expect(page.store.getSnapshot().rows.get("appearance.background")?.customized).toBe(false);
    expect(redoButton().disabled).toBe(false);
    expect(redoButton().getAttribute("aria-label")).toBe("Redo: Background → Shuffle Paintings");

    await click(redoButton());
    expect(page.store.getSnapshot().rows.get("appearance.background")?.value).toBe("daily");
    expect(undoButton().disabled).toBe(false);
  });

  test("a theme level change is undoable (the host's theme.set)", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    await run(() => page!.store.setTheme("room", "Tokyo Night"));
    expect(page.store.appearance.nextUndo?.label).toBe("Theme → Tokyo Night");
    await run(() => page!.store.undoAppearance());
    expect(page.store.getSnapshot().host?.theme?.current.room).toBeNull();
  });

  test("Reset to Defaults asks inline, resets every appearance key set, and is itself undoable", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    await run(() => page!.store.set("appearance.background", "friedrich-forest-moonlight"));
    await run(() => page!.store.set("appearance.backgroundOpacity", 0.5));
    await run(() => page!.store.resetAppearanceToDefaults());
    const rows = page.store.getSnapshot().rows;
    expect(rows.get("appearance.background")?.customized).toBe(false);
    expect(rows.get("appearance.backgroundOpacity")?.customized).toBe(false);
    expect(page.store.appearance.nextUndo?.label).toBe("Appearance defaults");
    await run(() => page!.store.undoAppearance());
    const back = page.store.getSnapshot().rows;
    expect(back.get("appearance.background")?.value).toBe("friedrich-forest-moonlight");
    expect(back.get("appearance.backgroundOpacity")?.value).toBe(0.5);
  });

  test("Restore How It Was puts back what Appearance showed when it opened", async () => {
    page = await renderPage({
      path: "/settings/appearance",
      mock: { values: { "appearance.background": "friedrich-forest-moonlight" } },
    });
    await run(() => page!.store.set("appearance.background", "daily"));
    await run(() => page!.store.set("appearance.backgroundOpacity", 0.4));
    expect(page.store.appearanceChangedSinceOpened()).toBe(true);
    await run(() => page!.store.restoreAppearanceOpened());
    const rows = page.store.getSnapshot().rows;
    expect(rows.get("appearance.background")?.value).toBe("friedrich-forest-moonlight");
    expect(rows.get("appearance.backgroundOpacity")?.customized).toBe(false);
    expect(page.store.appearanceChangedSinceOpened()).toBe(false);
    expect(page.store.appearance.nextUndo?.label).toBe("Appearance as opened");
  });

  test("other parts of Appearance record their own steps through trackAppearance", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    await run(() =>
      page!.store.trackAppearance(["appearance.background"], () => page!.store.set("appearance.background", "daily"), {
        label: "Rotation",
      }),
    );
    // The inner write records too; the outer step names the whole change.
    expect(page.store.appearance.nextUndo?.label).toBe("Rotation");
  });
});

describe("Appearance's presets", () => {
  const frosted = APPEARANCE_PRESETS.find((preset) => preset.id === "frosted")!;

  test("a preset sets Opacity and Material and puts every surface back on the window, as one step", async () => {
    page = await renderPage({
      path: "/settings/appearance",
      mock: {
        values: {
          "appearance.background": "friedrich-forest-moonlight",
          "appearance.surfaces.sidebar.opacity": 0.2,
          "appearance.surfaces.diff.opacity": 0.9,
        },
      },
    });
    await run(() => page!.store.applyAppearancePreset(frosted));
    const rows = page.store.getSnapshot().rows;
    expect(rows.get("appearance.backgroundOpacity")?.value).toBe(0.8);
    expect(rows.get("appearance.backgroundBlur")?.value).toBe("frosted");
    expect(rows.get("appearance.surfaces.sidebar.opacity")?.customized).toBe(false);
    expect(rows.get("appearance.surfaces.diff.opacity")?.customized).toBe(false);
    // A preset never touches the picture.
    expect(rows.get("appearance.background")?.value).toBe("friedrich-forest-moonlight");
    expect(activePreset(page.store.getSnapshot())).toBe("frosted");
    expect(page.store.appearance.nextUndo?.label).toBe("Presets → Frosted");

    await run(() => page!.store.undoAppearance());
    const back = page.store.getSnapshot().rows;
    expect(back.get("appearance.backgroundOpacity")?.customized).toBe(false);
    expect(back.get("appearance.surfaces.sidebar.opacity")?.value).toBe(0.2);
    expect(back.get("appearance.surfaces.diff.opacity")?.value).toBe(0.9);
    expect(page.store.appearance.canUndo).toBe(false);
  });

  test("a slider moved after a preset leaves it", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    await run(() => page!.store.applyAppearancePreset(frosted));
    await run(() => page!.store.set("appearance.surfaces.sidebar.opacity", 0.5));
    expect(activePreset(page.store.getSnapshot())).toBeNull();
  });

  test("the floating bar's Presets menu applies the picked preset", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    const button = page.container.querySelector<HTMLButtonElement>('[data-menu="appearance-presets"]')!;
    expect(button.disabled).toBe(false);
    await click(button);
    const item = [...document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find(
      (row) => row.textContent?.includes("Glass") && !row.textContent.includes("Frosted"),
    )!;
    await click(item);
    const rows = page.store.getSnapshot().rows;
    expect(rows.get("appearance.backgroundOpacity")?.value).toBe(0.6);
    expect(rows.get("appearance.backgroundBlur")?.value).toBe("glass");
  });
});
