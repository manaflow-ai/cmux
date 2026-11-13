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
} from "./resumeState";
import type { Subagent } from "./subagentFold";

type Agent = Pick<Subagent, "id" | "state" | "parent" | "resumable" | "resumes" | "resumedBy" | "harness">;
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
