import { describe, expect, test } from "bun:test";
import { RunCloudHttpError } from "../services/runs/legacy/cloudClientContract";
import { labelRunStage, runFailureDetail } from "../services/runs/legacy/failureStage";

// Staging dogfood run 39363650255 ended "Run source/setup, recipe, or Cloud
// operation failed" with nothing to say which step. The receipt names the step
// and only safe facts (HTTP status, a short error code, the guest exit code),
// never a provider or guest message.
describe("Run failure stage", () => {
  test("names the stage and the HTTP status and code of a Cloud operation", async () => {
    const error = await labelRunStage("vm-create", async () => {
      throw new RunCloudHttpError("POST", 403, { error: "vm_limit_exceeded", message: "You have 5 active machines; secret detail" });
    }).catch((caught) => caught);
    expect(runFailureDetail(error)).toBe(" (vm-create, HTTP 403, vm_limit_exceeded)");
    expect(error.message).toBe("Cloud POST operation failed (403)");
  });

  test("names the guest exit code for a failed guest command", async () => {
    const error = await labelRunStage("guest-command", async () => {
      throw Object.assign(new Error("Guest source/setup or recipe failed"), { exitCode: 1 });
    }).catch((caught) => caught);
    expect(runFailureDetail(error)).toBe(" (guest-command, exit 1)");
  });

  test("a frozen error passes through unchanged", async () => {
    class Pending extends Error {}
    const frozen = Object.freeze(new Pending("later"));
    const error = await labelRunStage("vm-create", async () => { throw frozen; }).catch((caught) => caught);
    expect(error).toBe(frozen);
    expect(runFailureDetail(error)).toBe("");
  });

  test("keeps the first, innermost stage", async () => {
    const error = await labelRunStage("execute", () => labelRunStage("source-receipt", async () => {
      throw new Error("receipt mismatch");
    })).catch((caught) => caught);
    expect(runFailureDetail(error)).toBe(" (source-receipt)");
  });

  test("never echoes an unsafe code, an unknown stage, or a non-error", () => {
    expect(runFailureDetail(new RunCloudHttpError("POST", 500, { error: "Bad <html> with spaces" }))).toBe("");
    expect(runFailureDetail(Object.assign(new Error("x"), { runStage: "made-up" }))).toBe("");
    expect(runFailureDetail("string")).toBe("");
    expect(runFailureDetail(undefined)).toBe("");
  });

  test("keeps a control-flow error's class so the worker still recognizes it", async () => {
    class Pending extends Error {}
    const error = await labelRunStage("vm-create", async () => { throw new Pending("later"); }).catch((caught) => caught);
    expect(error).toBeInstanceOf(Pending);
  });
});
