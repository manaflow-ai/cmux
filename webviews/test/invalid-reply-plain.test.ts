// A reply this cmux can't read says so in plain words (the app and its agent service are different
// versions) instead of "Invalid checkpoint attestation."; the specific reason stays on the error.
import { expect, test } from "bun:test";
import { checkpointRecord } from "../src/agent-session/acpmux/checkpoints/protocol";
import { translate } from "../src/agent-session/acpmux/i18n";
import { InvalidReplyError } from "../src/agent-session/acpmux/invalidReply";

test("an unreadable checkpoint reply reads as a version mismatch and keeps its reason", () => {
  let thrown: unknown;
  try {
    checkpointRecord("not an object");
  } catch (error) {
    thrown = error;
  }
  expect(thrown).toBeInstanceOf(InvalidReplyError);
  const error = thrown as InvalidReplyError;
  expect(error.message).toBe(translate("error.versionMismatch"));
  expect(error.message).not.toContain("Invalid");
  expect(error.detail).toContain("Invalid");
});
