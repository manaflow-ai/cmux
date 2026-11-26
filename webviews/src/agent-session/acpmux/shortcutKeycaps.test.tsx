import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { experimentArm } from "../../experiments/experiment";
import { ShortcutKeycaps } from "./ButtonKeycaps";
import { ariaKeyshortcuts, ShortcutKeycapLookContext, splitShortcutKeycaps } from "./shortcutKeycaps";
import { shortcutKeycaps, type ShortcutKeycapLook } from "./shortcutKeycaps.experiment";

const overridesAtStart = Object.getOwnPropertyDescriptor(globalThis, "cmuxExperiments");
afterEach(() => {
  if (overridesAtStart) Object.defineProperty(globalThis, "cmuxExperiments", overridesAtStart);
  else delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const render = (shortcut: string | undefined, look?: ShortcutKeycapLook) =>
  renderToStaticMarkup(
    look ? (
      <ShortcutKeycapLookContext value={look}>
        <ShortcutKeycaps shortcut={shortcut} />
      </ShortcutKeycapLookContext>
    ) : (
      <ShortcutKeycaps shortcut={shortcut} />
    ),
  );

test("the experiment is off by default, so buttons draw no keycaps", () => {
  expect(shortcutKeycaps.defaultArm).toBe("off");
  expect(experimentArm(shortcutKeycaps, { overrides: {}, stored: {} })).toBe("off");
  expect(render("⇧⌘D")).toBe("");
});

test("a display string splits into one cap per key, a chord into strokes", () => {
  expect(splitShortcutKeycaps("⇧⌘P")).toEqual([["⇧", "⌘", "P"]]);
  expect(splitShortcutKeycaps("⌃⌥⇧⌘F12")).toEqual([["⌃", "⌥", "⇧", "⌘", "F12"]]);
  expect(splitShortcutKeycaps("⌘K ⌘S")).toEqual([
    ["⌘", "K"],
    ["⌘", "S"],
  ]);
  expect(splitShortcutKeycaps("⌘Space")).toEqual([["⌘", "Space"]]);
  expect(splitShortcutKeycaps("")).toEqual([]);
  expect(splitShortcutKeycaps(undefined)).toEqual([]);
});

test("the shortcut is named in aria-keyshortcuts syntax", () => {
  expect(ariaKeyshortcuts("⇧⌘P")).toBe("Shift+Meta+P");
  expect(ariaKeyshortcuts("⌃⌥↩")).toBe("Control+Alt+Enter");
  expect(ariaKeyshortcuts("⌘K ⌘S")).toBe("Meta+K Meta+S");
  expect(ariaKeyshortcuts(undefined)).toBeUndefined();
});

test("each look draws the live shortcut, and none without one", () => {
  const filled = render("⇧⌘D", "filled");
  expect(filled).toContain('data-look="filled"');
  expect(filled).toContain('aria-hidden="true"');
  expect(filled.match(/<kbd/g)?.length).toBe(3);
  expect(render("⇧⌘D", "outlined").match(/<kbd/g)?.length).toBe(3);
  const compact = render("⇧⌘D", "compact");
  expect(compact.match(/<kbd/g)?.length).toBe(1);
  expect(compact).toContain(">⇧⌘D</kbd>");
  expect(render(undefined, "filled")).toBe("");
  // A rebind is a new string from the host: the caps are the new keys.
  expect(render("⌃⌥T", "compact")).toContain(">⌃⌥T</kbd>");
});

test("dogfood turns it on through the experiment's override", () => {
  globalThis.cmuxExperiments = { "shortcut-keycaps": "outlined" };
  expect(render("⌘D")).toContain('data-look="outlined"');
});
