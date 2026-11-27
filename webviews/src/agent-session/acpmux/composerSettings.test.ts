import { expect, test } from "bun:test";
import { DEFAULT_COMPOSER, readComposerSettings } from "./composerSettings";

test("preserves the native voice button opt-in in the composer page model", () => {
  expect(DEFAULT_COMPOSER.voiceButton).toBe(false);
  expect(readComposerSettings({ voiceButton: true }).voiceButton).toBe(true);
  expect(readComposerSettings({ voiceButton: "true" }).voiceButton).toBe(false);
});
