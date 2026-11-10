import { describe, expect, test } from "bun:test";
import { translate } from "./i18n";
import { askOwnerRequest, machineShareOutcome, offersMachineShare, shareMachineWithMe } from "./machineShare";
import { NativeError } from "./nativeError";

describe("offersMachineShare", () => {
  test("only a teammate's machine offers Share with Me", () => {
    expect(offersMachineShare("agent_session.team_vm_blocked")).toBe(true);
    for (const code of [undefined, "", "app.folder_needed", "agent_session.host_unverified"]) {
      expect(offersMachineShare(code)).toBe(false);
    }
  });
});

describe("machineShareOutcome", () => {
  test("an answer is a share", () => {
    expect(machineShareOutcome({ ok: true })).toEqual({ kind: "shared" });
  });
  test("only the creator or an admin shares: Ask the Owner next", () => {
    const error = new NativeError({ code: "machine.creator_or_admin", userMessage: "not allowed to share_chat this" });
    expect(machineShareOutcome({ ok: false, error })).toEqual({ kind: "forbidden" });
  });
  test("the platform's other refusals are keyed on their code, never their words", () => {
    expect(machineShareOutcome({ ok: false, error: { code: "machine.private", message: "x" } })).toEqual({
      kind: "failed",
      key: "switch.share.private",
    });
    for (const code of ["timed_out", "transport", "no_backend"]) {
      expect(machineShareOutcome({ ok: false, error: { code, message: "connection refused" } })).toEqual({
        kind: "failed",
        key: "switch.share.unavailable",
      });
    }
    expect(
      machineShareOutcome({ ok: false, error: { code: "machine.not_member", message: "share with a member of this team" } }),
    ).toEqual({ kind: "failed", key: "switch.share.failed", reason: "share with a member of this team" });
  });
  test("the retired classic codes are no longer special", () => {
    expect(machineShareOutcome({ ok: false, error: { code: "vm_chat_share_forbidden" } })).toEqual({
      kind: "failed",
      key: "switch.share.failed",
    });
  });
  test("anything else says the app's reason, or none", () => {
    expect(
      machineShareOutcome({
        ok: false,
        error: new NativeError({ code: "gesture_required", userMessage: " Click again. " }),
      }),
    ).toEqual({ kind: "failed", key: "switch.share.failed", reason: "Click again." });
    expect(machineShareOutcome({ ok: false, error: undefined })).toEqual({
      kind: "failed",
      key: "switch.share.failed",
    });
  });
});

describe("shareMachineWithMe", () => {
  test("maps the native call's answer and its refusal", async () => {
    expect(await shareMachineWithMe(async () => ({ shared: true }))).toEqual({ kind: "shared" });
    expect(
      await shareMachineWithMe(async () => {
        throw new NativeError({ code: "machine.creator_or_admin" });
      }),
    ).toEqual({ kind: "forbidden" });
  });
});

describe("askOwnerRequest", () => {
  test("names the machine, and no menu item the owner does not have", () => {
    const text = askOwnerRequest(translate, "build-box");
    expect(text).toContain("build-box");
    expect(text).not.toContain("Share Machine…");
    expect(askOwnerRequest(translate, undefined)).not.toContain("Share Machine…");
  });
});
