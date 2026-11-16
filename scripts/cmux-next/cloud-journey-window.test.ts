import { describe, expect, test } from "bun:test";
import { createTraceDetail, createTraceFields, createTraceNotice, JOURNEY_ONLY_STEPS, publicError, publicMachineFacts, spareFields, spareNotice } from "./cloud-journey";
import { runJourney } from "./cloud-journey-fake";

const journeyOnly = (name: string) => (JOURNEY_ONLY_STEPS as readonly string[]).includes(name);

describe("the first-text window holds only what a person's chat waits on", () => {
  test("no journey-only step is recorded between running and first text; each still runs, after the reply", () => {
    const { steps, probe } = runJourney({ spare: "report", exec: "ok" });
    // A step recorded while the machine runs and no first text has come yet is inside J.firstText's window.
    const inWindow = steps.filter((s) => s.fields?.create_marks_ms?.running !== undefined && s.fields.create_marks_ms.first_text === undefined);
    expect(inWindow.map((s) => s.step)).toContain("running (status)");
    expect(inWindow.filter((s) => journeyOnly(s.step)).map((s) => s.step)).toEqual([]);
    const reply = steps.findIndex((s) => s.step === "reply");
    expect(steps[reply]?.status).toBe("pass");
    for (const name of ["listed", "first exec", "machine facts", "GitHub on the machine (stub)"]) {
      const at = steps.findIndex((s) => s.step === name);
      expect(at).toBeGreaterThan(reply);
      expect(steps[at].status).not.toBe("fail");
    }
    expect(probe.outcome).toBe("ok");
    expect(probe.create_to_first_text_ms).toBeNumber();
  });
});

describe("probe.json says whether the row was a spare hit", () => {
  test("the claim answer's spare_fallback and spare_skips, and claimed_spare from the guest timeline", () => {
    const { probe } = runJourney({ spare: "report", exec: "ok" });
    expect(probe.spare_fallback).toBe("all_skipped");
    expect(probe.spare_skips).toEqual({ restarting: 1, image: 1 });
    expect(probe.claimed_spare).toBe(true);
    expect(probe).not.toHaveProperty("failure_facts");
  });

  test("null while the claim answer carries neither field", () => {
    const { probe } = runJourney({ spare: "none", exec: "ok" });
    expect(probe).toHaveProperty("spare_fallback", null);
    expect(probe).toHaveProperty("spare_skips", null);
    expect(probe.claimed_spare).toBe(true);
  });

  test("value.claim.behind (cmux-platform#1429) and the notice every create writes", () => {
    const behind = spareFields({ spare_fallback: null, spare_skips: { image: 1 }, claim: { id: "vm_x", behind: true } });
    expect(behind.claimed_behind).toBe(true);
    expect(spareFields({ spare_fallback: null, spare_skips: {}, claim: { id: "vm_x" } }).claimed_behind).toBe(false);
    expect(spareNotice("staging", "after", behind)).toBe('::notice title=Cloud journey spare::backend=staging phase=after fallback=null behind=true skips={"image":1}');
    expect(spareNotice("prod", "", spareFields({ spare_fallback: "all_skipped", spare_skips: { image: 2 } }))).toBe('::notice title=Cloud journey spare::backend=prod phase=- fallback=all_skipped behind=null skips={"image":2}');
  });

  test("only counts and reason tokens get through", () => {
    expect(publicError('exec: HTTP 503 "vm_unavailable" on vm_01JABCDEF9 at https://x.invalid/v1 from 10.1.2.3')).toBe('exec: HTTP 503 "vm_unavailable" on <id> at <url> from <addr>');
    // A guest's stderr names hosts with no scheme; daemon versions (1.0.0+abc) are not hosts.
    expect(publicError("exit 1 dial relay.example-host.internal: refused (daemon 1.0.0)")).toBe("exit 1 dial <host>: refused (daemon 1.0.0)");
    expect(spareFields({ spare_fallback: "no_spare", spare_skips: { restarting: 2, "vm_abc host": 1, image: -1, stale: 1.5 } })).toEqual({ spare_fallback: "no_spare", spare_skips: { restarting: 2 }, claimed_behind: null });
    expect(spareFields({ spare_fallback: "vm_0123 was lost", spare_skips: ["restarting"] })).toEqual({ spare_fallback: null, spare_skips: null, claimed_behind: null });
    expect(spareFields({ spare_fallback: null, spare_skips: {} })).toEqual({ spare_fallback: null, spare_skips: {}, claimed_behind: null });
    expect(publicMachineFacts({ id: "vm_x", host: "h.internal", status: "running", ready: false, team: "team_1", image: { daemon_version: "0.9.1", id: "img_1" }, updater: { flip: "pending", target: "vm_y" } }))
      .toEqual({ status: "running", ready: false, daemon_version: "0.9.1", updater_flip: "pending" });
  });
});

describe("probe.json carries the platform's create trace (a spare claim's server-side split)", () => {
  const claim = { attempt: 1, outcome: "spare_claim", steps: { capability: 1, budget: 3, plan_read: 12, entitlements: 14, rate_limit: 15, needs_rule: 16, scaler: 20, adopt: 40, spare_claim: 55 }, totalMs: 61 };

  test("createTraceFields keeps the outcome token, attempt, totalMs and each step's ms; nothing else gets through", () => {
    expect(createTraceFields({ id: "vm_01JABCDEF9", host: "h.internal", createTrace: claim })).toEqual(claim);
    expect(createTraceFields({ createTrace: { ...claim, steps: { budget: 3, vm_01JABCDEF9: 2, "a b": 1, neg: -1, frac: 1.5, str: "4" } } })?.steps).toEqual({ budget: 3 });
    expect(createTraceFields({ createTrace: { outcome: "vm_01JABCDEF9 failed", steps: [], totalMs: -3 } })).toEqual({ attempt: null, outcome: null, steps: {}, totalMs: null });
    expect(createTraceFields({ id: "vm_x" })).toBeNull();
    expect(createTraceFields(null)).toBeNull();
    expect(createTraceFields({ createTrace: "ok" })).toBeNull();
  });

  test("the step detail lists the steps in the order they ended, and the notice every run writes", () => {
    expect(createTraceDetail(claim)).toBe("spare_claim in 61 ms (attempt 1): capability 1, budget 3, plan_read 12, entitlements 14, rate_limit 15, needs_rule 16, scaler 20, adopt 40, spare_claim 55");
    expect(createTraceNotice("staging", "after", claim)).toBe('::notice title=Cloud journey create trace::backend=staging phase=after outcome=spare_claim total_ms=61 steps={"capability":1,"budget":3,"plan_read":12,"entitlements":14,"rate_limit":15,"needs_rule":16,"scaler":20,"adopt":40,"spare_claim":55}');
    expect(createTraceNotice("prod", "", null, "GET /v1/machines/vm_01JABCDEF9: HTTP 404")).toBe("::notice title=Cloud journey create trace::backend=prod phase=- outcome=none reason=GET /v1/machines/<id>: HTTP 404");
  });

  test("the journey reads it at client-config's platform origin after the reply, never inside the first-text window", () => {
    const { steps, probe, log } = runJourney({ spare: "report", exec: "ok", trace: "spare" });
    const step = steps.find((s) => s.step === "create trace");
    expect(step?.status).toBe("pass");
    expect(step?.detail).toContain("spare_claim in 61 ms");
    expect(steps.indexOf(step!)).toBeGreaterThan(steps.findIndex((s) => s.step === "reply"));
    expect(JOURNEY_ONLY_STEPS as readonly string[]).toContain("create trace");
    expect(log).toContain("platform trace read");
    expect(probe.create_trace).toEqual(claim);
    expect(probe.outcome).toBe("ok");
  });

  test("no trace on the record, or no platform origin: a skip with the reason, a null row field, the journey still passes", () => {
    for (const trace of ["absent", "none"] as const) {
      const { steps, probe } = runJourney({ spare: "report", exec: "ok", trace });
      const step = steps.find((s) => s.step === "create trace");
      expect(step?.status).toBe("skip");
      expect(step?.detail).toContain(trace === "absent" ? "no createTrace" : "platform_origin");
      expect(probe).toHaveProperty("create_trace", null);
      expect(probe.outcome).toBe("ok");
    }
  });
});

describe("a failed step after create reads the machine's facts before anything is deleted", () => {
  test("a claimed machine answering 503 vm_unavailable: the first exec says so, the facts are read, then the delete", () => {
    const { steps, probe, log } = runJourney({ spare: "report", exec: "unavailable" });
    const failed = steps.filter((s) => s.status === "fail");
    // The agent start is now the first step to reach the machine: it names the unavailable machine.
    expect(failed[0].step).toBe("start agent (claude)");
    expect(failed[0].detail).toContain("did not take its first exec");
    expect(failed[0].detail).toContain("vm_unavailable");
    // The journey-only checks still ran, and `first exec` still fails on it.
    expect(steps.find((s) => s.step === "first exec")?.status).toBe("fail");
    const facts = steps.findIndex((s) => s.step === "failure facts");
    const del = steps.findIndex((s) => s.step === "delete (cleanup)");
    expect(facts).toBeGreaterThan(-1);
    expect(del).toBeGreaterThan(facts);
    expect(steps[del].status).toBe("pass");
    // In the fake's own order: the facts' get and timeline exec, then the delete.
    expect(log.indexOf("exec timeline")).toBeGreaterThan(-1);
    expect(log.indexOf("delete")).toBeGreaterThan(log.indexOf("exec timeline"));
    expect(log.lastIndexOf("get", log.indexOf("delete"))).toBeGreaterThan(-1);
    expect(probe.outcome).toBe("fail");
    expect(probe.failure_facts.machine).toEqual({ status: "running", ready: true, daemon_version: "0.9.1" });
    expect(probe.failure_facts.timeline).toBeNull();
    expect(probe.failure_facts.timeline_error).toContain("vm_unavailable");
    expect(probe.spare_fallback).toBe("all_skipped");
    expect(probe.claimed_spare).toBeNull();
    // probe.json is public: no machine id, host or token.
    const text = JSON.stringify(probe);
    for (const leak of ["vm_01JFIXTURE7Q", "host-fixture", "fake-access", "fake-install-token"]) expect(text).not.toContain(leak);
  });
});
