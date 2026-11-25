// Leo 2026-11-02: a subagent's Session Info read "Back to 01a18a35-b1e8-7951-ba2f-703bf916b…": the
// chat's name was its raw session id. A back button names what spawned the subagent only by a
// readable name, else says "Back"; a chat named only by its raw id reads by its title.
import { expect, test } from "bun:test";
import { translate } from "../src/agent-session/acpmux/i18n";
import { subagentBackLabel } from "../src/agent-session/acpmux/session-info/subagentScope";
import { isRawId, sessionTitle } from "../src/agent-session/acpmux/sessionList";

const UUID = /[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/iu;
const t = (key: Parameters<typeof translate>[0], values?: Parameters<typeof translate>[1]) =>
  translate(key, values, "en");

test("a back button never names a raw id", () => {
  for (const parent of [
    "01a18a35-b1e8-7951-ba2f-703bf916b2c4",
    "01a15779-0000-7000-8000-000000000000/toolu_01H9abc",
    "toolu_01H9abc",
    "",
    "   ",
  ]) {
    const label = subagentBackLabel(t, parent);
    expect(label).toBe("Back");
    expect(label).not.toMatch(UUID);
  }
});

test("a back button names a readable parent", () => {
  expect(subagentBackLabel(t, "Fix the timeouts")).toBe("Back to Fix the timeouts");
  expect(subagentBackLabel(t, "claude-sr2-coord")).toBe("Back to claude-sr2-coord");
});

test("raw ids are told apart from names", () => {
  expect(isRawId("01A18A35-B1E8-7951-BA2F-703BF916B2C4")).toBe(true);
  expect(isRawId("Reviewer")).toBe(false);
  expect(isRawId("review-01a18a35")).toBe(false);
});

test("a chat named only by its raw session id reads by its title", () => {
  const id = "01a18a35-b1e8-7951-ba2f-703bf916b2c4";
  expect(sessionTitle({ sessionId: id, name: id, title: "Review merged PRs" }, t)).toBe("Review merged PRs");
  expect(sessionTitle({ sessionId: id, name: id }, t)).toBe(t("sidebar.newChat"));
  expect(sessionTitle({ sessionId: id, name: "claude-sr2-coord", harness: "codex" }, t)).toBe("claude-sr2-coord");
});
