// A prompt whose chat's saved policy acpmux could not read back from its log (a disk I/O error) is
// refused, and acpmux stops the chat's old agent (`Hub::refuse_cleared_host`). The refusal said
// only "this chat's log could not be read, ..." in acpmux's own words, and the card read it as a
// generic failure. acpmux now types it (`errorKind: policy.replay_failed`), and the card says why in
// the person's language, with Retry: sending again starts a fresh agent.
import { expect, test } from "bun:test";
import { failureCopy, failureKind, failureRecovery, typedFailureCode } from "../src/agent-session/acpmux/failureCopy";
import { translatorFor } from "../src/agent-session/acpmux/i18n";

const claude = { name: "Claude Code", harness: "claude" };
// The refusal's turn_result, as acpmux's fail_unstarted_turn writes it.
const refused = {
  status: "failed",
  error: "The chat's saved policy could not be read; its agent was stopped.",
  errorKind: "policy.replay_failed",
  recovery: "Send the message again to start a fresh agent. The daemon's log names the error that stopped the read.",
};

test("a failed policy replay says why the prompt was refused, localized, with Retry", () => {
  const code = typedFailureCode(refused.errorKind, undefined);
  expect(code).toBe("policy.replay_failed");
  expect(failureKind(refused.error, claude, code)).toBe("policy-replay-failed");
  expect(failureCopy(translatorFor("en"), refused.error, claude, code)).toBe(
    "The chat’s saved policy could not be read; its agent was stopped. Send again to start a fresh agent.",
  );
  expect(failureCopy(translatorFor("ja"), refused.error, claude, code)).toBe(
    "チャットに保存されたポリシーを読み込めなかったため、エージェントを停止しました。もう一度送信すると新しいエージェントが起動します。",
  );
  // Sending again starts a fresh agent: Retry is the way out.
  expect(failureRecovery("policy-replay-failed")).toBe("retry");
});

test("only the kinds the card names override the turn's code; the others keep their words", () => {
  // The agent's own code still reaches the card when acpmux's kind is not one the card names.
  expect(typedFailureCode("agent.exited", "context_length_exceeded")).toBe("context_length_exceeded");
  expect(typedFailureCode("disk.full", undefined)).toBeUndefined();
  expect(typedFailureCode(undefined, 7)).toBeUndefined();
  expect(typedFailureCode("toString", undefined)).toBeUndefined();
  // A kind the card names wins over the agent's code.
  expect(typedFailureCode("policy.replay_failed", "context_length_exceeded")).toBe("policy.replay_failed");
});
