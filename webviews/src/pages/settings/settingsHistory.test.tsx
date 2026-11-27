// Settings > Appearance's Undo, Redo and Reset <card> on the daemon's durable settings history
// (settings-history-v1), reached through the page's host: one history for the page, the palette,
// the CLI and agents, so a change anyone made is one Undo away.
import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { APPEARANCE_CATEGORIES, appearanceAreas } from "./appearanceUndo";
import { areaResetGroup } from "./durableHistory";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, ops, renderPage, run, settle } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const bar = () => page!.container.querySelector<HTMLElement>("[data-appearance-bar]")!;
const undoButton = () => bar().querySelector<HTMLButtonElement>("[data-undo]")!;
const redoButton = () => bar().querySelector<HTMLButtonElement>("[data-redo]")!;
const row = (key: string) => page!.store.getSnapshot().rows.get(key);

describe("the bar's Undo and Redo on the durable history", () => {
  test("Undo takes the page's step back with settings.undo, Redo restores the undo's revision", async () => {
    page = await renderPage({ path: "/settings/personalization" });
    const tile = page.container.querySelector<HTMLButtonElement>('.backdrop-tile[aria-label="Shuffle Paintings"]')!;
    await click(tile);
    expect(undoButton().getAttribute("aria-label")).toBe("Undo: Background → Shuffle Paintings");

    // The pick writes the background and, beside it, the memory of what Off showed: one step.
    const picked = page.provider.durable.filter((entry) => entry.undoes === null).length;
    await click(undoButton());
    expect(ops(page.provider, "cmux.settings.undo")).toHaveLength(picked);
    // No second, parallel history: the undo writes nothing of its own.
    expect(ops(page.provider, "cmux.settings.reset")).toEqual([]);
    expect(row("appearance.background")?.customized).toBe(false);
    const undone = page.provider.durable.find((entry) => entry.undoes !== null)!;
    expect(undone.undoes).not.toBeNull();
    expect(redoButton().getAttribute("aria-label")).toBe("Redo: Background → Shuffle Paintings");

    await click(redoButton());
    expect(ops(page.provider, "cmux.settings.restore")).toEqual([{ revision: String(undone.revision) }]);
    expect(row("appearance.background")?.value).toBe("daily");
    expect(undoButton().getAttribute("aria-label")).toBe("Undo: Background → Shuffle Paintings");

    // The redo is the newest change: Undo takes it back again.
    const undos = ops(page.provider, "cmux.settings.undo").length;
    await click(undoButton());
    expect(ops(page.provider, "cmux.settings.undo").length).toBeGreaterThan(undos);
    expect(row("appearance.background")?.customized).toBe(false);
  });

  test("an agent's change is one Undo away, named by its row and who made it", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    expect(undoButton().disabled).toBe(true);
    page.provider.foreignSet("appearance.backgroundOpacity", 0.3, "mcp");
    await settle();
    await run(() => page!.store.refreshDurableHistory());
    expect(undoButton().disabled).toBe(false);
    expect(undoButton().getAttribute("aria-label")).toBe("Undo: Opacity (by an agent)");

    await click(undoButton());
    expect(ops(page.provider, "cmux.settings.undo")).toHaveLength(1);
    expect(row("appearance.backgroundOpacity")?.customized).toBe(false);
    expect(redoButton().disabled).toBe(false);
    await click(redoButton());
    expect(row("appearance.backgroundOpacity")?.value).toBe(0.3);
  });

  test("a step of several writes (a preset) undoes in one click", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    const { APPEARANCE_PRESETS } = await import("./appearancePresets");
    await run(() => page!.store.applyAppearancePreset(APPEARANCE_PRESETS.at(-1)!));
    const written = page.provider.durable.length;
    expect(written).toBeGreaterThan(0);
    await run(() => page!.store.undoAppearance());
    expect(ops(page.provider, "cmux.settings.undo")).toHaveLength(written);
    expect(page.store.appearance.canUndo).toBe(false);
    expect(page.provider.durable.at(-1)!.undoes).not.toBeNull();
  });

  test("a change after an undo clears Redo", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    await run(() => page!.store.set("appearance.backgroundOpacity", 0.5));
    await run(() => page!.store.undoAppearance());
    expect(redoButton().disabled).toBe(false);
    page.provider.foreignSet("appearance.background", "daily", "cli");
    await settle();
    await run(() => page!.store.refreshDurableHistory());
    expect(await run(() => page!.store.redoAppearance())).toBe(false);
    expect(ops(page.provider, "cmux.settings.restore")).toEqual([]);
    expect(redoButton().disabled).toBe(true);
  });

  test("a host without the durable history keeps the page's own stack", async () => {
    page = await renderPage({ path: "/settings/personalization", mock: { durableHistory: false } });
    const tile = page.container.querySelector<HTMLButtonElement>('.backdrop-tile[aria-label="Shuffle Paintings"]')!;
    await click(tile);
    await click(undoButton());
    expect(ops(page.provider, "cmux.settings.reset")).toEqual([{ key: "appearance.background" }]);
    expect(row("appearance.background")?.customized).toBe(false);
  });
});

describe("Reset <card> is one write", () => {
  const areas = APPEARANCE_CATEGORIES.flatMap((category) => appearanceAreas(category));

  test("a card that is one schema group resets with settings.reset_group", async () => {
    const area = areas.find((item) => areaResetGroup(item) !== null)!;
    page = await renderPage({ path: "/settings/appearance" });
    const key = area.keys.find((item) => !row(item)?.managed && rowsByKeyHasSample(item))!;
    page.provider.foreignSet(key, rowSample(key), "user");
    await settle();
    await run(() => page!.store.resetAppearanceArea(area));
    expect(ops(page.provider, "cmux.settings.reset_group")).toEqual([{ group: areaResetGroup(area) }]);
    expect(ops(page.provider, "cmux.settings.reset")).toEqual([]);
    expect(row(key)?.customized).toBe(false);
    expect(page.store.appearance.nextUndo?.label).toBe(`Reset ${area.title.text}`);
  });

  test("any other card resets its keys in one edit (settings.reset_keys)", async () => {
    const area = areas.find((item) => areaResetGroup(item) === null && item.keys.length > 1)!;
    page = await renderPage({ path: "/settings/appearance" });
    const keys = area.keys.filter((item) => rowsByKeyHasSample(item)).slice(0, 2);
    for (const key of keys) page.provider.foreignSet(key, rowSample(key), "user");
    await settle();
    await run(() => page!.store.resetAppearanceArea(area));
    expect(ops(page.provider, "cmux.settings.reset_keys")).toHaveLength(1);
    expect(ops(page.provider, "cmux.settings.reset")).toEqual([]);
    for (const key of keys) expect(row(key)?.customized).toBe(false);
    await run(() => page!.store.undoAppearance());
    expect(ops(page.provider, "cmux.settings.undo")).toHaveLength(1);
    for (const key of keys) expect(row(key)?.customized).toBe(true);
  });
});

/** A value the schema accepts for `key` that is not its default (its first accepted sample). */
function rowSample(key: string): unknown {
  const schemaRow = rowsBy(key);
  return schemaRow.accepts.find((value) => JSON.stringify(value) !== JSON.stringify(schemaRow.default));
}

function rowsByKeyHasSample(key: string): boolean {
  return rowSample(key) !== undefined;
}

function rowsBy(key: string) {
  const found = page!.store.getSnapshot().rows.get(key);
  if (!found) throw new Error(`no row ${key}`);
  return schemaRows.get(key)!;
}

const { rowsByKey: schemaRows } = await import("./schema");
