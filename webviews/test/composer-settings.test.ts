import { expect, test } from "bun:test";
import { DEFAULT_COMPOSER, readComposerSettings } from "../src/agent-session/acpmux/composerSettings";

test("composer spell checking is opt-in and off by default", () => {
  expect(DEFAULT_COMPOSER.spellChecking).toBe(false);
  expect(readComposerSettings({}).spellChecking).toBe(false);
  expect(readComposerSettings({ spellChecking: true }).spellChecking).toBe(true);
  expect(readComposerSettings({ spellChecking: "true" }).spellChecking).toBe(false);
});

test("attachments show inline by default; strip is the other view", () => {
  expect(DEFAULT_COMPOSER.attachmentView).toBe("inline");
  expect(readComposerSettings({}).attachmentView).toBe("inline");
  expect(readComposerSettings({ attachmentView: "strip" }).attachmentView).toBe("strip");
  expect(readComposerSettings({ attachmentView: "inline" }).attachmentView).toBe("inline");
  for (const bad of ["Strip", "row", 1, true, null]) {
    expect(readComposerSettings({ attachmentView: bad }).attachmentView).toBe("inline");
  }
});

test("switching the attachment view round-trips and keeps the other settings", () => {
  // The host's push after each Settings change: the whole value with only attachmentView changed.
  let settings = readComposerSettings({ ...DEFAULT_COMPOSER, showDictation: false, spellChecking: true });
  const seen: string[] = [];
  for (const view of ["strip", "inline", "strip", "inline"] as const) {
    settings = readComposerSettings({ ...settings, attachmentView: view });
    seen.push(settings.attachmentView);
    expect(settings).toEqual({ ...DEFAULT_COMPOSER, showDictation: false, spellChecking: true, attachmentView: view });
  }
  expect(seen).toEqual(["strip", "inline", "strip", "inline"]);
});

test("the page's attachment view choice applies at once and asks the host to keep it", async () => {
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  const writes: string[] = [];
  settings.registerAttachmentViewHost((view) => writes.push(view));
  try {
    settings.setAttachmentView("strip");
    settings.setAttachmentView("inline");
    expect(writes).toEqual(["strip", "inline"]);
  } finally {
    settings.registerAttachmentViewHost(undefined);
    settings.setComposerSettings(DEFAULT_COMPOSER);
  }
});
