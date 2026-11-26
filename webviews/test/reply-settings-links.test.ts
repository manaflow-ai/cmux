// ask-073fa3e7ff (Leo: "just give me the link for now"): a Settings link an agent writes in its
// answer is a link the pane draws and the host opens on that exact setting, not plain text.
import { expect, test } from "bun:test";
import { appHref, linkHref } from "../src/agent-session/acpmux/replyHref";

test("a settings link in an answer is an app link", () => {
  for (const href of [
    "cmux://settings",
    "cmux://settings/connections/github",
    "cmux-nightly://settings/terminal/terminal.fontSize",
    "cmux://settings/models/add",
  ]) {
    expect(appHref(href)).toBeDefined();
    expect(linkHref(href)).toBeDefined();
  }
});

test("a malformed settings link stays text", () => {
  for (const href of ["cmux://settings/a b", "cmux://settingsx/a", "javascript://settings/a"]) {
    expect(appHref(href)).toBeUndefined();
  }
});
