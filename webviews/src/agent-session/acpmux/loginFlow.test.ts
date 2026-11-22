// Row 6 of the competitor teardown: provider sign-in is a flow bound to the chosen target that
// acpmux verifies; opening the login terminal is not success.
import { expect, test } from "bun:test";
import { translate } from "./i18n";
import { loginFlowEnded, loginFlowTarget, loginFlowText, readLoginFlow, type LoginFlowPhase } from "./loginFlow";

const reply = (phase: string, extra: Record<string, unknown> = {}) => ({
  flowId: "f1",
  phase,
  target: { harness: "codex", host: "devbox", cwd: "/work/app" },
  startedAt: 1,
  expiresAt: 900_001,
  updatedAt: 1,
  ...extra,
});

test("a flow reply reads back; anything malformed is no flow", () => {
  expect(readLoginFlow(reply("waiting", { reason: "not_yet" }))).toEqual({
    flowId: "f1",
    phase: "waiting",
    target: { harness: "codex", host: "devbox", cwd: "/work/app" },
    startedAt: 1,
    expiresAt: 900_001,
    reason: "not_yet",
  });
  expect(readLoginFlow(undefined)).toBeUndefined();
  expect(readLoginFlow(reply("done"))).toBeUndefined();
  expect(readLoginFlow({ ...reply("waiting"), flowId: "" })).toBeUndefined();
  expect(readLoginFlow({ ...reply("waiting"), target: undefined })).toBeUndefined();
});

test("only succeeded, failed, cancelled and expired end a flow", () => {
  const ended: LoginFlowPhase[] = ["succeeded", "failed", "cancelled", "expired"];
  for (const phase of ["starting", "waiting", "verifying", ...ended] as LoginFlowPhase[])
    expect(loginFlowEnded(phase)).toBe(ended.includes(phase));
});

test("opening the login says to finish it, never that it is done", () => {
  const t = translate;
  const waiting = loginFlowText(readLoginFlow(reply("waiting"))!, t);
  expect(waiting).toBe(t("loginFlow.waiting"));
  expect(waiting).not.toBe(t("loginFlow.succeeded"));
  expect(loginFlowText(readLoginFlow(reply("waiting", { reason: "peer_unreachable" }))!, t)).toBe(
    t("loginFlow.waitingMachine"),
  );
  expect(loginFlowText(readLoginFlow(reply("failed", { reason: "open_failed" }))!, t)).toBe(t("loginFlow.openFailed"));
  expect(loginFlowText(readLoginFlow(reply("failed", { reason: "not_signed_in" }))!, t)).toBe(t("loginFlow.failed"));
  for (const phase of ["starting", "verifying", "succeeded", "cancelled", "expired"])
    expect(loginFlowText(readLoginFlow(reply(phase))!, t)).not.toBe("");
});

test("a flow is bound to the composer's chosen target, never to a chat's session", () => {
  const target = { harness: "codex", host: "devbox", cwd: "/work/app" };
  expect(loginFlowTarget({ target })).toBe(target);
  expect(loginFlowTarget({ sessionId: "s1" })).toBeUndefined();
  expect(loginFlowTarget(undefined)).toBeUndefined();
});
