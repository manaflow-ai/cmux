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

// Review of #46874: a failed start's card stays, and the person picks again. Its pick must not keep covering
// the chip or go with the next send; only a start that is running names its pick.
test("only a running Cloud start's pick shows on the composer", () => {
  const pick = { harness: "codex", model: "gpt-6.1-sol" };
  expect(shownCloudStartPick(true, { state: "starting", pick })).toEqual(pick);
  expect(shownCloudStartPick(true, { state: "failed", pick })).toBeUndefined();
  expect(shownCloudStartPick(false, { state: "starting", pick })).toBeUndefined();
  expect(shownCloudStartPick(true, undefined)).toBeUndefined();
});
