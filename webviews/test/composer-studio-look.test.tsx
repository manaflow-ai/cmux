// Studio's composer look (composerLook.ts `studio`): only Settings' agentPane.composerLook picks it,
// it lays the row inside the box as the former Codex row does, a gallery preview still wins over it,
// and New Tab stays Claude's. The default (`auto`) is unchanged.
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { lookRowInBox, setPreviewComposerLook, useComposerLook } from "../src/agent-session/acpmux/composerLook";
import {
  DEFAULT_COMPOSER,
  readComposerSettings,
  setComposerSettings,
} from "../src/agent-session/acpmux/composerSettings";

function Look() {
  return <span>{useComposerLook()}</span>;
}
const currentLook = () => renderToStaticMarkup(<Look />);

afterEach(() => {
  setPreviewComposerLook();
  setComposerSettings({ composerLook: "auto" });
});

test("the setting defaults to auto, reads studio, and reads anything else as auto", () => {
  expect(DEFAULT_COMPOSER.composerLook).toBe("auto");
  expect(readComposerSettings({}).composerLook).toBe("auto");
  expect(readComposerSettings({ composerLook: "studio" }).composerLook).toBe("studio");
  for (const bad of ["Studio", "studio ", "codex", "claude", 3])
    expect(readComposerSettings({ composerLook: bad }).composerLook).toBe("auto");
});

test("the default draws the standard composer; studio draws Studio's", () => {
  expect(currentLook()).toBe("<span>claude</span>");
  setComposerSettings({ composerLook: "studio" });
  expect(currentLook()).toBe("<span>studio</span>");
});

test("a gallery preview wins over the setting, and clearing it brings the setting back", () => {
  setComposerSettings({ composerLook: "studio" });
  setPreviewComposerLook("codex");
  expect(currentLook()).toBe("<span>codex</span>");
  setPreviewComposerLook();
  expect(currentLook()).toBe("<span>studio</span>");
});

test("Studio's row sits in the box as the former Codex row; Claude's stays under it", () => {
  expect(lookRowInBox("studio")).toBe(true);
  expect(lookRowInBox("codex")).toBe(true);
  expect(lookRowInBox("claude")).toBe(false);
});
