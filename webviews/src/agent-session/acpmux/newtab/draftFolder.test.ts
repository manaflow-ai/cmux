import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "../model";
import { shownCloudStartPick, withCloudStartPick } from "./draftFolder";

const page = { sessionId: undefined, summary: undefined } as unknown as AcpmuxSnapshot;

// cmux#45774: GPT-6.1 Sol picked on the New Tab page and sent to Cloud, then the chat view's model chip read Opus 5.5
// (the picker's default) while the start ran.
test("a Cloud start's agent and model show on the composer while it runs", () => {
  const shown = withCloudStartPick(page, { harness: "codex", model: "gpt-6.1-sol" });
  expect(shown.summary?.harness).toBe("codex");
  expect(shown.summary?.model).toBe("gpt-6.1-sol");
  expect(withCloudStartPick(page, { harness: "codex" }).summary?.model).toBeUndefined();
  expect(withCloudStartPick(page, undefined)).toBe(page);
});

// Review of #46874: a failed start's card stays for its Retry. Until the person picks again, the chip and the Retry
// keep the agent and model that start sent: a New Tab's Codex pick lives only in the start (the chat under it names
// no agent), so dropping it retried as the first installed agent. A pick made since replaces it.
test("a Cloud start's pick shows while it runs, and after it fails until the person picks again", () => {
  const pick = { harness: "codex", model: "gpt-6.1-sol", over: {} };
  const unchanged = { harness: undefined, model: undefined };
  expect(shownCloudStartPick(true, { state: "starting", pick }, unchanged)).toEqual(pick);
  expect(shownCloudStartPick(true, { state: "failed", pick }, unchanged)).toEqual(pick);
  expect(shownCloudStartPick(true, { state: "failed", pick }, { harness: "claude", model: "opus" })).toBeUndefined();
  const overChat = { ...pick, over: { harness: "claude", model: "opus" } };
  expect(shownCloudStartPick(true, { state: "failed", pick: overChat }, { harness: "claude", model: "opus" })).toEqual(
    overChat,
  );
  expect(
    shownCloudStartPick(true, { state: "failed", pick: overChat }, { harness: "claude", model: "sonnet" }),
  ).toBeUndefined();
  expect(shownCloudStartPick(false, { state: "starting", pick }, unchanged)).toBeUndefined();
  expect(shownCloudStartPick(true, undefined, unchanged)).toBeUndefined();
});
