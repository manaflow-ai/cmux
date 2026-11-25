// Switch Automatically in the Background card (Leo, 2026-11-14: "the auto switching that macos
// does ... for this app"): each mode writes the keys the app's engine reads, Off puts one picture
// back, every change is one undo step, and an editor opening never moves the picker grid.
import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { installDom } from "./testDom";
import {
  formatWhen,
  modeOf,
  nextWhen,
  parseWhen,
  renameWhen,
  writesFor,
  type WallpaperValues,
  readMemory,
} from "./wallpaperSwitch";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { act } = await import("react");
const { changeValue, click, ops, renderPage, run, settle } = await import("./testing");

const SONOMA = "system:/System/Library/Desktop Pictures/Sonoma.madesktop";
const HARBOR = "file:/Users/me/Pictures/Harbor.png";

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

async function card(values: Record<string, unknown> = { "appearance.background": "friedrich-forest-moonlight" }) {
  page = await renderPage({ path: "/settings/appearance", mock: { values } });
  await act(async () =>
    page!.provider.setHost({
      ...page!.provider.host,
      backdrops: [
        ...(page!.provider.host.backdrops ?? []),
        { id: SONOMA, title: "Sonoma", attribution: "", collection: "apple", collection_title: "Apple", dynamic: true },
        { id: HARBOR, title: "Harbor", attribution: "", collection: "yours", collection_title: "Your images" },
      ],
    }),
  );
  await settle();
  return page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
}

const control = () => page!.container.querySelector<HTMLElement>("[data-wallpaper-switch]")!;
// Found by attribute, not a selector: the selector engine reads the & of "Light & Dark" as CSS nesting.
const mode = (title: string) =>
  [...control().querySelectorAll<HTMLInputElement>("input[aria-label]")].find(
    (input) => input.getAttribute("aria-label") === title,
  )!;
const value = (key: string) => page!.store.getSnapshot().rows.get(key)?.value ?? null;
// The settings file as it stands: every row a write customized, which is all a fresh load reads.
const storedSettings = () =>
  Object.fromEntries(
    [...page!.store.getSnapshot().rows].filter(([, row]) => row.customized).map(([key, row]) => [key, row.stored]),
  );
// The switch's own writes; the memory the card keeps beside them is tested on its own.
const sets = () =>
  (ops(page!.provider, "cmux.settings.set") as Array<{ key: string; value: unknown }>).filter(
    (write) => write.key !== "appearance.backgroundMemory",
  );
const memoryWrites = () =>
  (ops(page!.provider, "cmux.settings.set") as Array<{ key: string; value: unknown }>).filter(
    (write) => write.key === "appearance.backgroundMemory",
  );

describe("the model", () => {
  const off: WallpaperValues = {
    background: "friedrich-forest-moonlight",
    light: null,
    dark: null,
    schedule: null,
    dynamic: "appearance",
  };
  const choices = [{ id: SONOMA, title: "Sonoma", dynamic: true }];

  test("when keys parse and print back", () => {
    for (const key of ["07:00", "23:59", "sunrise", "sunset-30m", "sunrise+1h", "dusk+90m", "noon-2h"])
      expect(formatWhen(parseWhen(key)!)).toBe(key);
    expect(parseWhen("sunset+60m")).toEqual({ kind: "sun", event: "sunset", offset: 60 });
    expect(formatWhen(parseWhen("sunset+60m")!)).toBe("sunset+1h");
    for (const bad of ["24:00", "7:00", "moonrise", "sunset-", "sunset*3"]) expect(parseWhen(bad)).toBeNull();
  });

  test("a new row takes a free when, and a rename keeps the row's place or refuses a taken key", () => {
    expect(nextWhen({ sunrise: "a" })).toBe("sunset");
    const schedule = { "07:00": "a", sunset: "b", dusk: "c" };
    expect(Object.keys(renameWhen(schedule, "sunset", "sunset-30m")!)).toEqual(["07:00", "sunset-30m", "dusk"]);
    expect(renameWhen(schedule, "sunset", "dusk")).toBeNull();
  });

  test("the values' mode", () => {
    expect(modeOf(off, choices)).toBe("off");
    expect(modeOf({ ...off, background: "appearance" }, choices)).toBe("appearance");
    expect(modeOf({ ...off, background: "schedule" }, choices)).toBe("schedule");
    expect(modeOf({ ...off, background: "folder:/Users/me/Pictures" }, choices)).toBe("rotate");
    expect(modeOf({ ...off, background: SONOMA, dynamic: "time" }, choices)).toBe("sun");
    // A dynamic picture on its light and dark frames is one picture, as macOS shows it.
    expect(modeOf({ ...off, background: SONOMA }, choices)).toBe("off");
    // A still with dynamic left on time is still Off.
    expect(modeOf({ ...off, dynamic: "time" }, choices)).toBe("off");
  });

  test("Off after a mode without a picture of its own puts the last fixed one back", () => {
    expect(
      writesFor("off", { ...off, background: "daily" }, { choices, lastFixed: "friedrich-forest-moonlight" }),
    ).toEqual([["appearance.background", "friedrich-forest-moonlight"]]);
    expect(writesFor("off", { ...off, background: "daily" }, { choices, lastFixed: null })).toEqual([
      ["appearance.background", "none"],
    ]);
    expect(writesFor("off", { ...off, background: SONOMA, dynamic: "time" }, { choices, lastFixed: null })).toEqual([
      ["appearance.backgroundDynamic", null],
    ]);
  });

  test("Off from Rotate with no last picture shows a picture another mode still names, not none", () => {
    expect(
      writesFor("off", { ...off, background: "folder:/Users/me/Art", light: HARBOR }, { choices, lastFixed: null }),
    ).toEqual([["appearance.background", HARBOR]]);
  });
});

// Leo, 2026-11-19: "i was examining my background settings and switched around from the rotating to
// day/night/whatever but it lost the folder or something idk i couldn't get back into it? i couldn't
// see the prev[iew]". Each mode keeps what it showed while another mode is on.
describe("switching modes never loses a mode's folder or picture", () => {
  const ART = "folder:/Users/me/Art";
  const folderChoice = (title: string) =>
    [...control().querySelectorAll<HTMLInputElement>(".wallpaper-editor input[type=radio]")].find(
      (input) => input.getAttribute("aria-label") === title,
    );

  test("Rotate goes back to the folder it shuffled after Light & Dark and Time of Day", async () => {
    await card({ "appearance.background": ART });
    expect(control().dataset.wallpaperSwitch).toBe("rotate");
    await click(mode("Light & Dark"));
    expect(value("appearance.background")).toBe("appearance");
    await click(mode("Rotate"));
    expect(value("appearance.background")).toBe(ART);
    expect(folderChoice("Art")?.checked).toBe(true);
    await click(mode("Time of Day"));
    await click(mode("Off"));
    await click(mode("Rotate"));
    expect(value("appearance.background")).toBe(ART);
  });

  test("the folder survives leaving Appearance in another mode, and the picker offers it again", async () => {
    await card({ "appearance.background": ART });
    await click(mode("Light & Dark"));
    const kept = storedSettings();
    page!.unmount();
    page = null;
    const backdrop = await card({
      ...kept,
      "appearance.background": "appearance",
      "appearance.backgroundLight": HARBOR,
    });
    // The grid still has the folder's tile, so one click recovers it.
    const tile = backdrop.querySelector<HTMLButtonElement>('.backdrop-grid [aria-label="Shuffling Art"]');
    expect(tile).not.toBeNull();
    await click(mode("Rotate"));
    expect(value("appearance.background")).toBe(ART);
  });

  test("a chosen No Wallpaper is what Off puts back, also after the card remounts", async () => {
    await card({ "appearance.background": "none" });
    await click(mode("Rotate"));
    const kept = storedSettings();
    page!.unmount();
    page = null;
    await card({ ...kept, "appearance.background": "daily", "appearance.backgroundLight": HARBOR });
    await click(mode("Off"));
    expect(value("appearance.background")).toBe("none");
  });

  // A new Settings web view, or cmux after a restart, starts with nothing but the stored settings:
  // the page's own memory and its web view's storage are empty. What the modes showed must come
  // back from the settings file.
  test("the folder comes back after a fresh load that keeps only the stored settings", async () => {
    await card({ "appearance.background": ART });
    await click(mode("Light & Dark"));
    const stored = storedSettings();
    page!.unmount();
    page = null;
    const backdrop = await card(stored);
    expect(backdrop.querySelector('.backdrop-grid [aria-label="Shuffling Art"]')).not.toBeNull();
    await click(mode("Rotate"));
    expect(value("appearance.background")).toBe(ART);
  });

  test("Off's picture comes back after a fresh load that keeps only the stored settings", async () => {
    await card({ "appearance.background": "none", "appearance.backgroundLight": HARBOR });
    await click(mode("Rotate"));
    const stored = storedSettings();
    page!.unmount();
    page = null;
    await card(stored);
    await click(mode("Off"));
    expect(value("appearance.background")).toBe("none");
  });

  test("the memory is a stored setting: opening writes nothing, leaving a mode keeps its value", async () => {
    await card({ "appearance.background": ART });
    expect(memoryWrites()).toEqual([]);
    await click(mode("Light & Dark"));
    expect(value("appearance.backgroundMemory")).toEqual({ rotate: ART, folder: ART });
    // Not an undo step: Undo puts Rotate back, and the memory stays.
    await run(() => page!.store.undoAppearance());
    expect(value("appearance.background")).toBe(ART);
    expect(readMemory(value("appearance.backgroundMemory")).folder).toBe(ART);
  });

  test("a stored memory of the wrong shape reads as none", () => {
    expect(readMemory({ rotate: "munch-scream", folder: "daily", off: "daily" })).toEqual({
      rotate: null,
      folder: null,
      off: null,
    });
    expect(readMemory("folder:/Users/me/Art")).toEqual({ rotate: null, folder: null, off: null });
    expect(readMemory({ rotate: ART, folder: ART, off: "none" })).toEqual({ rotate: ART, folder: ART, off: "none" });
  });

  test("Off after Rotate keeps the picture on screen before it", async () => {
    await card({ "appearance.background": ART, "appearance.backgroundLight": HARBOR });
    await click(mode("Off"));
    expect(value("appearance.background")).toBe(HARBOR);
  });
});

describe("Switch Automatically in the Background card", () => {
  test("Light & Dark keeps the current picture as Light, then each slot sets its side", async () => {
    await card();
    await click(mode("Light & Dark"));
    expect(sets()).toEqual([
      { key: "appearance.backgroundLight", value: "friedrich-forest-moonlight" },
      { key: "appearance.background", value: "appearance" },
    ]);
    expect(control().dataset.wallpaperSwitch).toBe("appearance");
    const dark = control().querySelector<HTMLButtonElement>('.wallpaper-slot[aria-label^="Dark picture"]')!;
    await click(dark);
    await click(control().querySelector<HTMLButtonElement>('.wallpaper-slot-picker [aria-label="Harbor"]')!);
    expect(value("appearance.backgroundDark")).toBe(HARBOR);
    expect(control().querySelector(".wallpaper-slot-picker")).toBeNull();
  });

  test("Time of Day starts with the picture at sunrise and sunset; rows change, add and remove", async () => {
    await card();
    await click(mode("Time of Day"));
    expect(value("appearance.background")).toBe("schedule");
    expect(value("appearance.backgroundSchedule")).toEqual({
      sunrise: "friedrich-forest-moonlight",
      sunset: "friedrich-forest-moonlight",
    });
    // Sunset to 30 minutes before it, through the offset menu's form mirror.
    const sunset = control().querySelector<HTMLElement>('[data-when="sunset"]')!;
    const offset = sunset.querySelectorAll<HTMLSelectElement>("select.ui-select-native")[1]!;
    await changeValue(offset, "-30");
    expect(value("appearance.backgroundSchedule")).toEqual({
      sunrise: "friedrich-forest-moonlight",
      "sunset-30m": "friedrich-forest-moonlight",
    });
    // Sunrise to a clock time.
    const sunrise = control().querySelector<HTMLElement>('[data-when="sunrise"]')!;
    await changeValue(sunrise.querySelector<HTMLSelectElement>("select.ui-select-native")!, "time");
    const time = control().querySelector<HTMLInputElement>('[data-when="06:30"] input[type="time"]')!;
    await changeValue(time, "07:15");
    expect(Object.keys(value("appearance.backgroundSchedule") as object)).toEqual(["07:15", "sunset-30m"]);
    // A row's picture.
    await click(control().querySelector<HTMLButtonElement>('[data-when="07:15"] .wallpaper-slot')!);
    await click(control().querySelector<HTMLButtonElement>('.wallpaper-slot-picker [aria-label="Harbor"]')!);
    expect((value("appearance.backgroundSchedule") as Record<string, string>)["07:15"]).toBe(HARBOR);
    // Add, then remove.
    const add = [...control().querySelectorAll<HTMLButtonElement>("button")].find(
      (b) => b.textContent === "Add a Time",
    )!;
    await click(add);
    expect(Object.keys(value("appearance.backgroundSchedule") as object)).toEqual(["07:15", "sunset-30m", "sunrise"]);
    await click(control().querySelector<HTMLButtonElement>('[data-when="sunrise"] [aria-label^="Remove"]')!);
    expect(Object.keys(value("appearance.backgroundSchedule") as object)).toEqual(["07:15", "sunset-30m"]);
    // A sun event asks where the sun is; empty is the time zone's place.
    const location = control().querySelector<HTMLInputElement>(".wallpaper-location")!;
    await changeValue(location, "37.77, -122.42");
    await act(async () => location.dispatchEvent(new window.FocusEvent("focusout", { bubbles: true })));
    await settle();
    expect(value("appearance.backgroundLocation")).toBe("37.77,-122.42");
  });

  test("Sun uses the current dynamic picture, or the first one, and follows the sun", async () => {
    await card();
    await click(mode("Sun"));
    expect(sets()).toEqual([
      { key: "appearance.background", value: SONOMA },
      { key: "appearance.backgroundDynamic", value: "time" },
    ]);
    expect(control().dataset.wallpaperSwitch).toBe("sun");
    // Off keeps the picture and puts it back on its light and dark frames.
    await click(mode("Off"));
    expect(value("appearance.background")).toBe(SONOMA);
    expect(page!.store.getSnapshot().rows.get("appearance.backgroundDynamic")?.customized).toBe(false);
  });

  test("Rotate shuffles the paintings and draws Change Picture in its editor", async () => {
    await card();
    await click(mode("Rotate"));
    expect(value("appearance.background")).toBe("daily");
    const editor = control().querySelector<HTMLElement>(".wallpaper-editor")!;
    expect(editor.querySelector('[data-row-key="appearance.backgroundRotation"]')).not.toBeNull();
    // Only one Change Picture row in the card.
    expect(page!.container.querySelectorAll('[data-row-key="appearance.backgroundRotation"]').length).toBe(1);
  });

  test("switching back to Off restores a fixed background", async () => {
    await card();
    await click(mode("Rotate"));
    await click(mode("Off"));
    expect(value("appearance.background")).toBe("friedrich-forest-moonlight");
    await click(mode("Light & Dark"));
    await click(mode("Off"));
    expect(value("appearance.background")).toBe("friedrich-forest-moonlight");
    expect(control().dataset.wallpaperSwitch).toBe("off");
  });

  test("a mode change is one undo step, named by the mode", async () => {
    await card();
    await click(mode("Light & Dark"));
    expect(page!.store.appearance.nextUndo?.label).toBe("Switch Automatically → Light & Dark");
    await run(() => page!.store.undoAppearance());
    expect(value("appearance.background")).toBe("friedrich-forest-moonlight");
    expect(page!.store.getSnapshot().rows.get("appearance.backgroundLight")?.customized).toBe(false);
    expect(control().dataset.wallpaperSwitch).toBe("off");
    await run(() => page!.store.redoAppearance());
    expect(value("appearance.background")).toBe("appearance");
    expect(value("appearance.backgroundLight")).toBe("friedrich-forest-moonlight");
  });

  test("an editor opening never moves the picker grid", async () => {
    const backdrop = await card();
    const grid = backdrop.querySelector<HTMLElement>(".backdrop-grid")!;
    const box = JSON.stringify(grid.getBoundingClientRect());
    const tiles = grid.children.length;
    await click(mode("Time of Day"));
    await click(control().querySelector<HTMLButtonElement>(".wallpaper-slot")!);
    const after = backdrop.querySelector<HTMLElement>(".backdrop-grid")!;
    // The same element, the same tiles, the same box; the editor and its picture list come after it.
    expect(after).toBe(grid);
    expect(grid.children.length).toBe(tiles);
    expect(JSON.stringify(grid.getBoundingClientRect())).toBe(box);
    expect(grid.compareDocumentPosition(control()) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(grid.contains(control().querySelector(".wallpaper-slot-picker"))).toBe(false);
  });
});
