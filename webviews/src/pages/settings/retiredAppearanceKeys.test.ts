// #22379 took Glass Transparency (a second opacity) and the legacy Backdrop Art chooser off the page,
// but their keys still load: a Glass Transparency someone set still thins the glass with
// Experimental Appearance Controls on, and nothing in Settings could put it back. Appearance's
// Reset to Defaults now resets those retired keys too (and Undo puts them back).
import { expect, test } from "bun:test";
import { appearanceKeys, captureKeys, tracksAppearance } from "./appearanceUndo";
import type { ListRow } from "./ops";
import type { SettingsState } from "./store";

const GLASS = "appearance.glassTransparency";
const ART = "appearance.backdropArt";

test("Reset to Defaults covers the retired appearance keys that still load", () => {
  expect(appearanceKeys()).toContain(GLASS);
  expect(appearanceKeys()).toContain(ART);
  expect(tracksAppearance(GLASS)).toBe(true);
});

test("a Glass Transparency someone set is captured, so Reset to Defaults resets it", () => {
  const row = { key: GLASS, value: 0.4, default: 0, customized: true, managed: null } as unknown as ListRow;
  const state = { rows: new Map([[GLASS, row]]) } as unknown as SettingsState;
  expect(captureKeys(state, appearanceKeys())).toEqual([{ kind: "setting", key: GLASS, value: 0.4, customized: true }]);
});

test("the other page-hidden keys stay out (another surface edits them)", () => {
  expect(appearanceKeys()).not.toContain("sidebar.workspaceRow.agent.icon");
  expect(appearanceKeys()).not.toContain("appearance.interfaceScale");
});
