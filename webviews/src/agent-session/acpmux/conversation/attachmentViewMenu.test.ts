// l10n-allow-file: test fixtures.
// A sent prompt's right-click offers Attachments Inline / Attachments at Top over
// `agentPane.attachmentView` (Leo, 2026-11-27: "it should be toggleable one or the other"): the
// report says which one is in use, only for a prompt that carries attachments.
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "../model";
import { setComposerSettings } from "../composerSettings";
import { messageMenuTarget } from "./messageMenu";

const image = { id: "img-1", name: "shot.png", mimeType: "image/png", src: "cmux-image://img-1" };
const rows = [
  { id: "u1", kind: "user", text: "look at this", at: 1, images: [image] },
  { id: "u2", kind: "user", text: "no pictures", at: 2 },
  {
    id: "u3",
    kind: "user",
    text: "a file",
    at: 3,
    inlineParts: [
      { kind: "text", text: "a file " },
      { kind: "file", id: "f1", name: "notes.md" },
    ],
  },
  { id: "a1", kind: "assistant", text: "answer", at: 4 },
];
const snapshot = { canFork: false, isWorking: false, connection: "connected", rows } as unknown as AcpmuxSnapshot;

afterEach(() => setComposerSettings({ attachmentView: "strip" }));

test("a prompt with attachments reports the view in use", () => {
  setComposerSettings({ attachmentView: "strip" });
  expect(messageMenuTarget(snapshot, "u1")?.attachmentView).toBe("strip");
  expect(messageMenuTarget(snapshot, "u3")?.attachmentView).toBe("strip");
  setComposerSettings({ attachmentView: "inline" });
  expect(messageMenuTarget(snapshot, "u1")?.attachmentView).toBe("inline");
});

test("a prompt without attachments and a reply report no view", () => {
  expect(messageMenuTarget(snapshot, "u2")?.attachmentView).toBeUndefined();
  expect(messageMenuTarget(snapshot, "a1")?.attachmentView).toBeUndefined();
});
