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
    const error = new NativeError({ code: "vm_chat_share_forbidden", userMessage: "Only the machine's creator…" });
    expect(machineShareOutcome({ ok: false, error })).toEqual({ kind: "forbidden" });
  });
  test("the Cloud API's other refusals are keyed on their code, never their words", () => {
    expect(
      machineShareOutcome({ ok: false, error: { code: "vm_chat_grants_personal_machine", message: "x" } }),
    ).toEqual({
      kind: "failed",
      key: "switch.share.personal",
    });
    expect(machineShareOutcome({ ok: false, error: { code: "vm_chat_grants_unavailable" } })).toEqual({
      kind: "failed",
      key: "switch.share.unavailable",
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
        throw new NativeError({ code: "vm_chat_share_forbidden" });
      }),
    ).toEqual({ kind: "forbidden" });
  });
});

describe("askOwnerRequest", () => {
  test("names the machine and the menu item that shares it", () => {
    const text = askOwnerRequest(translate, "build-box");
    expect(text).toContain("build-box");
    expect(text).toContain("Share Machine…");
    expect(askOwnerRequest(translate, undefined)).toContain("Share Machine…");
  });
});
