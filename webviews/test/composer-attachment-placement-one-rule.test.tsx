// Leo, 2026-11-09 (ask-bdaa08fba5): "we have inline stuff, so why is this not inline? This one went
// above the whole thing. It's in, like, the special attachment zone. But we didn't say to do that."
// and "In the right-click menu for the composer ... all attachments in line, or all attachments at the
// top like normal."
//
// One placement rule for every attachment kind:
// 1. the view is `agentPane.attachmentView`, inline by default;
// 2. the composer's right-click offers Attachments Inline and Attachments at Top, checked by the
//    view, and picking one sets it;
// 3. detector: the inline view's placement (composer/inlineAttachments.tsx `place` and `ready`) never
//    reads what an attachment is (an image, a video, a file, a pasted chip), and the strip-only set
//    that kept an attachment above the text for good is gone. A kind branch or that set coming back
//    fails here. The behavior across kinds is test/inline-attachments-hook.test.tsx (7.).
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { attachmentViewMenu } from "../src/agent-session/acpmux/composer/attachmentViewMenu";
import {
  type AttachmentView,
  composerSettingsSnapshot,
  DEFAULT_COMPOSER,
  readComposerSettings,
  setAttachmentView,
  setComposerSettings,
} from "../src/agent-session/acpmux/composerSettings";
import { translate } from "../src/agent-session/acpmux/i18n";

afterEach(() => setComposerSettings({ attachmentView: "inline" }));

test("attachments show inline by default", () => {
  expect(DEFAULT_COMPOSER.attachmentView).toBe("inline");
  expect(readComposerSettings({}).attachmentView).toBe("inline");
  expect(readComposerSettings({ attachmentView: "sideways" }).attachmentView).toBe("inline");
  expect(readComposerSettings({ attachmentView: "strip" }).attachmentView).toBe("strip");
});

test("the right-click offers Attachments Inline and Attachments at Top, checked by the view", () => {
  const items = (view: AttachmentView) => attachmentViewMenu(view, translate);
  expect(items("inline").map((item) => [item.label, item.checked])).toEqual([
    ["Attachments Inline", true],
    ["Attachments at Top", false],
  ]);
  expect(items("strip").map((item) => item.checked)).toEqual([false, true]);
  // The "both" view a cmux-next.json can set checks neither; picking one replaces it.
  expect(items("both").map((item) => item.checked)).toEqual([false, false]);
  expect(items("inline")[0]!.separatorBefore).toBe(true);
});

test("picking an item sets the attachment view", () => {
  expect(composerSettingsSnapshot().attachmentView).toBe("inline");
  attachmentViewMenu("inline", translate)[1]!.onSelect();
  expect(composerSettingsSnapshot().attachmentView).toBe("strip");
  attachmentViewMenu("strip", translate)[0]!.onSelect();
  expect(composerSettingsSnapshot().attachmentView).toBe("inline");
  // The same path the host persists through (pane.setAttachmentView).
  setAttachmentView("strip");
  expect(composerSettingsSnapshot().attachmentView).toBe("strip");
});

test("the composer's right-click menu holds the attachment view items", () => {
  const composer = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/Composer.tsx"), "utf8");
  const menu = composer.slice(composer.indexOf("const fieldMenu: ContextMenuItem[] = ["));
  expect(menu.slice(0, menu.indexOf("];"))).toContain("...attachmentViewMenu(attachmentView, t)");
});

/// The body of `name(` in `source`, through its matching brace.
function body(source: string, name: string): string {
  const start = source.indexOf(`    ${name}(`);
  expect(start).toBeGreaterThan(-1);
  const open = source.indexOf("{", source.indexOf(")", start));
  let depth = 0;
  for (let at = open; at < source.length; at++) {
    if (source[at] === "{") depth++;
    else if (source[at] === "}" && --depth === 0) return source.slice(open, at + 1);
  }
  throw new Error(`no end for ${name}`);
}

test("detector: the inline placement never branches on an attachment's kind and keeps nothing strip-only", () => {
  const source = readFileSync(
    path.join(import.meta.dir, "../src/agent-session/acpmux/composer/inlineAttachments.tsx"),
    "utf8",
  );
  // Strip comments: the rule's own words name kinds.
  const code = (text: string) => text.replace(/\/\/[^\n]*/g, "").replace(/\/\*[\s\S]*?\*\//g, "");
  const kindReads =
    /\.(video|image|kind|mimeType|path|name|text|preview|size)\b|isVideo|isImage|isVideoName|isImageFile|isVideoAttachment/;
  for (const name of ["place", "ready"]) {
    const placement = code(body(source, name));
    expect({ name, read: placement.match(kindReads)?.[0] ?? null }).toEqual({ name, read: null });
  }
  expect(code(source)).not.toMatch(/stripOnly/);
});
