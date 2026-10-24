import { expect, test } from "bun:test";
import { DEFAULT_COMPOSER, readComposerSettings } from "../src/agent-session/acpmux/composerSettings";

test("composer spell checking is opt-in and off by default", () => {
  expect(DEFAULT_COMPOSER.spellChecking).toBe(false);
  expect(readComposerSettings({}).spellChecking).toBe(false);
  expect(readComposerSettings({ spellChecking: true }).spellChecking).toBe(true);
  expect(readComposerSettings({ spellChecking: "true" }).spellChecking).toBe(false);
});
