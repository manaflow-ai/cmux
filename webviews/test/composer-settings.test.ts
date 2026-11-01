import { expect, test } from "bun:test";
import { DEFAULT_COMPOSER, readComposerSettings } from "../src/agent-session/acpmux/composerSettings";

test("composer spell checking is opt-in and off by default", () => {
  expect(DEFAULT_COMPOSER.spellChecking).toBe(false);
  expect(readComposerSettings({}).spellChecking).toBe(false);
  expect(readComposerSettings({ spellChecking: true }).spellChecking).toBe(true);
  expect(readComposerSettings({ spellChecking: "true" }).spellChecking).toBe(false);
});

test("machine load warnings are on by default and accept an explicit off value", () => {
  expect(DEFAULT_COMPOSER.showMachineLoadWarnings).toBe(true);
  expect(readComposerSettings({}).showMachineLoadWarnings).toBe(true);
  expect(readComposerSettings({ showMachineLoadWarnings: false }).showMachineLoadWarnings).toBe(false);
  expect(readComposerSettings({ showMachineLoadWarnings: "false" }).showMachineLoadWarnings).toBe(true);
});

test("attachments show inline by default; strip and both are the other views", () => {
  expect(DEFAULT_COMPOSER.attachmentView).toBe("inline");
  expect(readComposerSettings({}).attachmentView).toBe("inline");
  expect(readComposerSettings({ attachmentView: "strip" }).attachmentView).toBe("strip");
  expect(readComposerSettings({ attachmentView: "inline" }).attachmentView).toBe("inline");
  expect(readComposerSettings({ attachmentView: "both" }).attachmentView).toBe("both");
  for (const bad of ["Strip", "Both", "row", 1, true, null]) {
    expect(readComposerSettings({ attachmentView: bad }).attachmentView).toBe("inline");
  }
});

test("switching the attachment view round-trips and keeps the other settings", () => {
  // The host's push after each Settings change: the whole value with only attachmentView changed.
  let settings = readComposerSettings({ ...DEFAULT_COMPOSER, showDictation: false, spellChecking: true });
  const seen: string[] = [];
  for (const view of ["strip", "inline", "both", "inline"] as const) {
    settings = readComposerSettings({ ...settings, attachmentView: view });
    seen.push(settings.attachmentView);
    expect(settings).toEqual({ ...DEFAULT_COMPOSER, showDictation: false, spellChecking: true, attachmentView: view });
  }
  expect(seen).toEqual(["strip", "inline", "both", "inline"]);
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

test("send-to-bottom defaults on and the composer toggle writes the host setting", async () => {
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  const writes: [string, boolean][] = [];
  expect(readComposerSettings({}).scrollToBottomOnSend).toBe(true);
  expect(readComposerSettings({ scrollToBottomOnSend: false }).scrollToBottomOnSend).toBe(false);
  settings.registerComposerHost((method, show) => writes.push([method, show]));
  try {
    settings.setScrollToBottomOnSend(false);
    settings.setScrollToBottomOnSend(true);
    expect(writes).toEqual([
      ["pane.setScrollToBottomOnSend", false],
      ["pane.setScrollToBottomOnSend", true],
    ]);
  } finally {
    settings.registerComposerHost(undefined);
    settings.setComposerSettings(DEFAULT_COMPOSER);
  }
});

test("a rejected send-to-bottom write rolls back the optimistic choice", async () => {
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  settings.setComposerSettings({ scrollToBottomOnSend: true });
  settings.registerComposerHost(() => Promise.reject(new Error("managed")));
  try {
    settings.setScrollToBottomOnSend(false);
    expect(settings.composerSettingsSnapshot().scrollToBottomOnSend).toBe(false);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(settings.composerSettingsSnapshot().scrollToBottomOnSend).toBe(true);
  } finally {
    settings.registerComposerHost(undefined);
    settings.setComposerSettings(DEFAULT_COMPOSER);
  }
});

test("a host snapshot wins over a late success from an older send-to-bottom write", async () => {
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  let resolveWrite!: () => void;
  settings.setComposerSettings({ scrollToBottomOnSend: true });
  settings.registerComposerHost(() => new Promise<void>((resolve) => (resolveWrite = resolve)));
  try {
    settings.setScrollToBottomOnSend(false);
    expect(settings.composerSettingsSnapshot().scrollToBottomOnSend).toBe(false);
    settings.setComposerSettings({ scrollToBottomOnSend: true });
    resolveWrite();
    await Promise.resolve();
    expect(settings.composerSettingsSnapshot().scrollToBottomOnSend).toBe(true);
    // A stale success must not poison the confirmed value used by a later rejected write.
    settings.registerComposerHost(() => Promise.reject(new Error("managed")));
    settings.setScrollToBottomOnSend(false);
    await Promise.resolve();
    expect(settings.composerSettingsSnapshot().scrollToBottomOnSend).toBe(true);
  } finally {
    settings.registerComposerHost(undefined);
    settings.setComposerSettings(DEFAULT_COMPOSER);
  }
});

test("new chats start on this Mac by default; Cloud only when the setting says so", () => {
  expect(DEFAULT_COMPOSER.newChatsIn).toBe("local");
  expect(readComposerSettings({}).newChatsIn).toBe("local");
  expect(readComposerSettings({ newChatsIn: "cloud" }).newChatsIn).toBe("cloud");
  expect(readComposerSettings({ newChatsIn: "Cloud" }).newChatsIn).toBe("local");
  expect(readComposerSettings({ newChatsIn: true }).newChatsIn).toBe("local");
});
