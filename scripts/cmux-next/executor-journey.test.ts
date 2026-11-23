import { describe, expect, test } from "bun:test";
import { guestCommand, parseGuest, phaseProblem, resultProblem, staleExecutorMachines } from "./executor-journey.ts";

const GOOD = { status: "completed", execution: { ok: true, value: { pages: 20, mentionsOverview: true, chars: 3886 }, toolCalls: [{ name: "deepwiki.read_wiki_structure", outcome: "success", durationMs: 556 }] }, unavailableApps: [] };

describe("executor journey", () => {
  test("parses the guest's phases and result", () => {
    const g = parseGuest(`EXJ host Linux x86_64 cmux\nEXJ install ok executor v2.0.0-beta.67 in 5 s\nnoise\nEXJ execute fail NotSignedIn 401\nEXJ result ${JSON.stringify(GOOD)}\n`);
    expect(g.host).toBe("Linux x86_64 cmux");
    expect(g.phases).toEqual([
      { phase: "install", ok: true, detail: "executor v2.0.0-beta.67 in 5 s" },
      { phase: "execute", ok: false, detail: "NotSignedIn 401" },
    ]);
    expect(g.result).toEqual(GOOD);
  });

  test("a real tool call is required", () => {
    expect(resultProblem(GOOD)).toBeNull();
    expect(resultProblem(null)).toContain("no `EXJ result`");
    expect(resultProblem({ ...GOOD, execution: { ...GOOD.execution, toolCalls: [] } })).toContain("no successful deepwiki");
    expect(resultProblem({ ...GOOD, execution: { ok: true, value: 2, toolCalls: [] } })).toContain("no successful deepwiki");
    expect(resultProblem({ ...GOOD, execution: { ...GOOD.execution, value: { pages: 0, mentionsOverview: false } } })).toContain("empty wiki");
    expect(resultProblem({ status: "paused" })).toContain("status");
  });

  test("a DeepWiki outage is named as the third party's, not Executor's", () => {
    expect(phaseProblem({ phase: "deepwiki", ok: false, detail: "HTTP 503" })).toContain("a third party) is down, not Executor");
    expect(phaseProblem({ phase: "execute", ok: false, detail: "NotSignedIn" })).toBe("Executor phase execute failed: NotSignedIn");
  });

  test("sweeps only its own old, idle machines", () => {
    const now = Date.UTC(2026, 10, 22, 12);
    const old = (now - 4 * 3_600_000).toString(36);
    const fresh = (now - 600_000).toString(36);
    const rows = [
      { id: "vm_a", name: `cmux-test-exec-${old}`, status: "running" },
      { id: "vm_b", name: `cmux-test-exec-${fresh}`, status: "running" },
      { id: "vm_c", name: `cmux-test-exec-${old}`, status: "running", last_active_at: now - 60_000 },
      { id: "vm_d", name: `cloud journey auto jr-${old}`, status: "running" },
      { id: "vm_e", name: `cmux-test-exec-${old}`, status: "deleted" },
    ];
    expect(staleExecutorMachines(rows, now)).toEqual([{ id: "vm_a", name: `cmux-test-exec-${old}` }]);
  });

  test("the guest command carries the script and a safe pin only", () => {
    expect(guestCommand("echo hi", "2.0.0-beta.67")).toContain("EXECUTOR_VERSION=2.0.0-beta.67 ");
    expect(guestCommand("echo hi", "1; rm -rf /")).not.toContain("EXECUTOR_VERSION");
    expect(guestCommand("echo hi")).toContain(Buffer.from("echo hi").toString("base64"));
  });
});
