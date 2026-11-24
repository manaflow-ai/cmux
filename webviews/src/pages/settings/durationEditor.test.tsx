// A time row whose range is too wide for a slider is a menu of durations (Lucas 2026-11-11: Hibernate
// After's slider sat "all the way at 0" at an hour of a week's range).
import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, ops, renderPage, rowElement } = await import("./testing");
const { durationLabel, isDuration } = await import("./editors/DurationEditor");
const { rowsByKey } = await import("./schema");

const HIBERNATE = "workspaces.hibernation.idleMinutes";

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

test("wide time ranges are menus; short ranges and other units keep their slider", () => {
  expect(isDuration(rowsByKey.get(HIBERNATE)!)).toBe(true);
  // 0 to 60 seconds in whole seconds: a slider shows it well.
  expect(isDuration(rowsByKey.get("notifications.suppressWhileTypingSeconds")!)).toBe(false);
  expect(isDuration(rowsByKey.get("notifications.sounds.volume")!)).toBe(false);
  expect(isDuration(rowsByKey.get("sidebar.hoverCards.delay")!)).toBe(false);
  // A 0 default means something of its own ("no limit", "at once"): the row keeps its slider.
  expect(isDuration(rowsByKey.get("history.closed.maxAgeDays")!)).toBe(false);
  expect(isDuration(rowsByKey.get("agents.autoRetry.intervalSeconds")!)).toBe(false);
  // A short span or a step few durations fit keeps the slider too.
  expect(isDuration(rowsByKey.get("notifications.sounds.cooldownSeconds")!)).toBe(false);
  expect(isDuration(rowsByKey.get("appearance.colorTransition.springResponse")!)).toBe(false);
});

test("a duration reads in the largest whole unit", () => {
  expect(durationLabel(3600)).toBe("1 hour");
  expect(durationLabel(15 * 60)).toBe("15 minutes");
  expect(durationLabel(14 * 86400)).toBe("2 weeks");
  expect(durationLabel(90)).toBe("90 seconds");
  // A zero reads in the row's own unit.
  expect(durationLabel(0, "day")).toBe("0 days");
});

test("Hibernate After is a menu on its value; a pick writes minutes, and Custom… opens the field", async () => {
  page = await renderPage({ path: "/settings/general" });
  const row = () => rowElement(page!.container, HIBERNATE);
  expect(row().querySelector('input[type="range"]')).toBeNull();
  const native = () => row().querySelector<HTMLSelectElement>("select.ui-select-native")!;
  expect(row().querySelector(".ui-select-button")?.textContent).toBe("1 hour");
  const labels = [...native().options].map((option) => option.textContent);
  expect(labels.slice(0, 3)).toEqual(["5 minutes", "10 minutes", "15 minutes"]);
  expect(labels.at(-1)).toBe("Custom…");
  await changeValue(native(), "120");
  expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: HIBERNATE, value: 120 }]);
  await changeValue(native(), "__custom__");
  expect(row().querySelector(".number-field input.number")).not.toBeNull();
});

test("Custom… left with no new value closes its field, and the menu shows the row's value again", async () => {
  page = await renderPage({ path: "/settings/general" });
  const row = () => rowElement(page!.container, HIBERNATE);
  const native = () => row().querySelector<HTMLSelectElement>("select.ui-select-native")!;
  await changeValue(native(), "__custom__");
  const field = row().querySelector<HTMLInputElement>(".number-field input.number")!;
  await act(async () => {
    field.focus();
    field.blur();
  });
  expect(row().querySelector(".number-field input.number")).toBeNull();
  expect(row().querySelector(".ui-select-button")?.textContent).toBe("1 hour");
  expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
});
