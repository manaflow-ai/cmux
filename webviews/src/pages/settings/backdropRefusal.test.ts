import { expect, test } from "bun:test";
import "./testCatalog";
import { isBackdropRefusal, linkRefusal } from "./backdropRefusal";
import { t } from "./strings";

// Choose Image and Add from a Link word the host's refusals alike: a file that is no picture or
// movie says so, never the generic "Invalid value" (Leo, 2026-11-21, on custom backgrounds: "we need
// to make sure we have good controls and settings and everything work sthere").
test("a picked file's refusal is worded as the link's", () => {
  expect(isBackdropRefusal("cmux.settings.backdrop.not_media")).toBe(true);
  expect(isBackdropRefusal("cmux.settings.backdrop.too_large")).toBe(true);
  expect(isBackdropRefusal("cmux.settings.invalid")).toBe(false);
  expect(isBackdropRefusal(undefined)).toBe(false);
  expect(linkRefusal("cmux.settings.backdrop.not_media")).toBe(t("settingsWindow.backdropPicker.notMedia"));
  expect(linkRefusal("cmux.settings.backdrop.not_media")).not.toBe(t("settingsPage.invalidValue"));
  expect(linkRefusal("anything else")).toBe(t("settingsWindow.backdropPicker.downloadFailed"));
});
