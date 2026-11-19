import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "../model";
import { withCloudStartPick } from "./draftFolder";

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
