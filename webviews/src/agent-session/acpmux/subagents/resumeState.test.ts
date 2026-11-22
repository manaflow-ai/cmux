import { describe, expect, test } from "bun:test";
import { RETRY_METHOD } from "./retryState";
import {
  applyResume,
  canResume,
  RESUME_CAPABILITY,
  resumedRun,
  resumeVersion,
  runResume,
  settledResume,
  shownResume,
  SUBSESSION_RESUME_CAPABILITY,
  subsessionResumeRow,
} from "./resumeState";
import type { Subagent } from "./subagentFold";

type Agent = Pick<Subagent, "id" | "state" | "parent" | "resumable" | "resumes" | "resumedBy" | "harness" | "child">;
const stopped = (over: Partial<Agent> = {}): Agent => ({ id: "s/t1", state: "cancelled", parent: null, ...over });
const served = new Set([RESUME_CAPABILITY]);

describe("a stopped subagent's Resume", () => {
  test("reads acpmux's resumable, resumes and resumedBy", () => {
    const agent = stopped();
    applyResume(agent, { resumable: true });
    expect(agent.resumable).toBe(true);
    applyResume(agent, { resumedBy: "s/t9" });
    expect(agent).toMatchObject({ resumable: false, resumedBy: "s/t9" });
    const run = stopped({ id: "s/t9", state: "running" });
    applyResume(run, { resumes: "s/t1" });
    expect(resumedRun(run, new Map([["s/t1", agent]]))).toBe(true);
    expect(resumedRun(run, new Map())).toBe(false);
  });

  test("is offered only on the chat's own stopped or lost subagent acpmux can resume", () => {
    expect(canResume(stopped({ resumable: true }), served)).toBe(true);
    expect(canResume(stopped({ resumable: true, state: "disconnected" }), served)).toBe(true);
    expect(canResume(stopped({ resumable: true }), undefined)).toBe(true);
    expect(canResume(stopped({ resumable: true }), new Set())).toBe(false);
    expect(canResume(stopped(), served)).toBe(false);
    expect(canResume(stopped({ resumable: true, state: "completed" }), served)).toBe(false);
    expect(canResume(stopped({ resumable: true, parent: "s/t0" }), served)).toBe(false);
    expect(canResume(stopped({ resumable: true, harness: "codex" }), served)).toBe(false);
  });

  test("asks acpmux to resume it in the same chat", async () => {
    const asked: [string, Record<string, unknown>][] = [];
    const request = async (method: string, params: Record<string, unknown>) => void asked.push([method, params]);
    const note = await runResume(stopped({ resumable: true }), "chat-1", { request, capabilities: served });
    expect(note).toBeUndefined();
    expect(asked).toEqual([[RETRY_METHOD, { sessionId: "chat-1", subagentId: "s/t1" }]]);
  });

  test("a refusal says why, and an unreachable chat is never asked", async () => {
    const busy = async () => Promise.reject({ reason: "retry.busy" });
    expect(await runResume(stopped({ resumable: true }), "c", { request: busy, capabilities: served })).toBe(
      "retry.busy",
    );
    let asked = false;
    const request = async () => void (asked = true);
    const note = await runResume(stopped({ resumable: true }), "c", { request, reaches: () => false });
    expect([note, asked]).toEqual(["retry.failed", false]);
  });
});

describe("a stopped sub-session's Resume", () => {
  const subsession = (over: Partial<Agent> = {}): Agent =>
    stopped({ id: "s/run-1", child: "child-1", harness: "codex", ...over });
  const both = new Set([RESUME_CAPABILITY, SUBSESSION_RESUME_CAPABILITY]);

  test("is offered on the chat's own stopped sub-session where acpmux serves it", () => {
    // acpmux carries its own chat on: no `resumable` needed, whatever its harness.
    expect(canResume(subsession(), new Set([SUBSESSION_RESUME_CAPABILITY]))).toBe(true);
    expect(canResume(subsession(), undefined)).toBe(true);
    expect(canResume(subsession({ harness: undefined }), both)).toBe(true);
    expect(canResume(subsession(), served)).toBe(false);
    expect(canResume(subsession(), new Set())).toBe(false);
  });

  test("is not offered on one that completed, failed, runs or was lost, nor on a nested one", () => {
    for (const state of ["completed", "failed", "running", "disconnected"])
      expect(canResume(subsession({ state }), both)).toBe(false);
    expect(canResume(subsession({ parent: "s/t0" }), both)).toBe(false);
  });

  test("asks acpmux to carry on its own session", async () => {
    const asked: [string, Record<string, unknown>][] = [];
    const request = async (method: string, params: Record<string, unknown>) => void asked.push([method, params]);
    expect(await runResume(subsession(), "chat-1", { request, capabilities: both })).toBeUndefined();
    expect(asked).toEqual([[RETRY_METHOD, { sessionId: "child-1" }]]);
    const busy = async () => Promise.reject({ reason: "retry.busy" });
    expect(await runResume(subsession(), "chat-1", { request: busy, capabilities: both })).toBe("retry.busy");
    const gone = async () => Promise.reject({ reason: "retry.nothing_failed" });
    expect(await runResume(subsession(), "chat-1", { request: gone, capabilities: both })).toBe("retry.nothingFailed");
  });

  test("leaves the Claude subagent's Resume as it was", () => {
    expect(canResume(stopped({ resumable: true }), new Set([SUBSESSION_RESUME_CAPABILITY]))).toBe(false);
    expect(canResume(stopped({ resumable: true }), both)).toBe(true);
    expect(canResume(stopped(), both)).toBe(false);
  });

  test("a session row resumes as a sub-session's row while its last turn ended stopped", async () => {
    expect(subsessionResumeRow({ sessionId: "child-1", name: "tests" })).toBeUndefined();
    const row = subsessionResumeRow({ sessionId: "child-1", title: "Run the tests", stoppedAt: 20 })!;
    expect(row).toMatchObject({ id: "child-1", child: "child-1", parent: null, name: "Run the tests" });
    expect(canResume(row, both)).toBe(true);
    const asked: Record<string, unknown>[] = [];
    const request = async (_: string, params: Record<string, unknown>) => void asked.push(params);
    await runResume(row, "chat-1", { request, capabilities: both });
    expect(asked).toEqual([{ sessionId: "child-1" }]);
    // A second stop keys a new note: a Resume that went last time does not hold this one.
    const again = subsessionResumeRow({ sessionId: "child-1", name: "tests", stoppedAt: 30 })!;
    expect(resumeVersion(again)).not.toBe(resumeVersion(row));
  });
});

describe("a Resume's busy and note, as every surface keeps them", () => {
  test("a Resume that went stays busy, a refusal leaves its note, both for the row's version", () => {
    expect(settledResume(3, undefined)).toEqual({ version: 3, busy: true });
    expect(settledResume(3, "retry.busy")).toEqual({ version: 3, key: "retry.busy" });
    expect(shownResume(settledResume(3, "retry.busy"), 3)?.key).toBe("retry.busy");
    expect(shownResume(settledResume(3, "retry.busy"), 4)).toBeUndefined();
    expect(shownResume(undefined, 3)).toBeUndefined();
  });

  test("a row with no version of its own changes it when acpmux takes or ends the Resume", () => {
    const agent = { state: "cancelled" as const, resumable: true, endedAt: 10 };
    const before = resumeVersion(agent);
    expect(resumeVersion({ ...agent })).toBe(before);
    expect(resumeVersion({ ...agent, resumedBy: "s/t9" })).not.toBe(before);
    expect(resumeVersion({ ...agent, resumable: false })).not.toBe(before);
    expect(resumeVersion({ ...agent, state: "running" })).not.toBe(before);
    expect(resumeVersion({ ...agent, endedAt: 11 })).not.toBe(before);
  });
});
