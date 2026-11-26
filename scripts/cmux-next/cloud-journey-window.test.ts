import { describe, expect, test } from "bun:test";
import { CHAT_START_SIZE, COLD_CREATE_SIZE, COLD_CREATE_STEP, createWithRoom, DEFAULT_SIZE_STEP, defaultSizeProblem, sizeReadingProblem, JOURNEY_ONLY_STEPS, publicError, publicMachineFacts, spareFields, spareNotice } from "./cloud-journey";
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

describe("a new machine at the default size is recorded at 2 vCPU / 4096 MB / 20480 MB", () => {
  test("the chat start size is the platform's spare size (cmux-platform#1756)", () => {
    expect({ ...CHAT_START_SIZE }).toEqual({ cpu: 2, memory_mb: 4096, disk_mb: 20480 });
    expect(defaultSizeProblem({ cpu: 2, memory_mb: 4096, disk_mb: 20480 })).toBeNull();
    expect(defaultSizeProblem({ cpu: 4, memory_mb: 16384, disk_mb: 65536 })).toContain("4/16384/65536");
    expect(defaultSizeProblem(undefined)).toContain("?/?/?");
  });

  test("the journey asks the default size and its read-back passes, after the reply", () => {
    const { steps, log } = runJourney({ spare: "report", exec: "ok" });
    expect(log).toContain(`create size ${JSON.stringify({ cpu: 2, memory_mb: 4096, disk_mb: 20480 })}`);
    const at = steps.findIndex((s) => s.step === DEFAULT_SIZE_STEP);
    expect(steps[at]?.status).toBe("pass");
    expect(at).toBeGreaterThan(steps.findIndex((s) => s.step === "reply"));
  });

  test("a machine recorded at another size fails the read-back", () => {
    const { steps } = runJourney({ spare: "report", exec: "ok", recordedSize: { cpu: 4, memory_mb: 16384, disk_mb: 65536 } });
    const step = steps.find((s) => s.step === DEFAULT_SIZE_STEP);
    expect(step?.status).toBe("fail");
    expect(step?.detail).toContain("4/16384/65536");
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

describe("a failed step after create reads the machine's facts before anything is deleted", () => {
  test("a claimed machine answering 503 vm_unavailable: the first exec says so, the facts are read, then the delete", () => {
    const { steps, probe, log } = runJourney({ spare: "report", exec: "unavailable" });
    const failed = steps.filter((s) => s.status === "fail");
    // The owner-kind wait is now the first step to reach the machine: it names the unavailable machine.
    expect(failed[0].step).toBe("machine kind owner");
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

describe("the cold create cell reads a person's own create at its asked size (cmux-platform#1513)", () => {
  test("sizeReadingProblem: the guest's reading at the asked size, a little under for kernel and filesystem", () => {
    expect(sizeReadingProblem("journey-ok\nx86_64\ncpu=4 mem_mib=16203 disk_mib=64328\n", { cpu: 4, memory_mb: 16384, disk_mb: 65536 })).toBeNull();
    expect(sizeReadingProblem("cpu=4 mem_mib=7900 disk_mib=32000", COLD_CREATE_SIZE)).toBeNull();
    expect(sizeReadingProblem("cpu=2 mem_mib=3900 disk_mib=16000", COLD_CREATE_SIZE)).toBe("booted at another size than asked: cpu 2 (asked 4), mem_mib 3900 (asked 8192), disk_mib 16000 (asked 32768)");
    expect(sizeReadingProblem("cpu=4 mem_mib=16203 disk_mib=64328", COLD_CREATE_SIZE)).toContain("mem_mib 16203 (asked 8192)");
    expect(sizeReadingProblem("journey-ok\nx86_64\n", COLD_CREATE_SIZE)).toStartWith("no cpu=, mem_mib= and disk_mib= reading");
  });

  test("off by default in the fake; on, it creates at the asked size, reads it on the guest, and deletes only its own machine", () => {
    const off = runJourney({ spare: "report", exec: "ok" });
    expect(off.steps.find((s) => s.step === COLD_CREATE_STEP)?.status).toBe("skip");
    const { steps, log, probe } = runJourney({ spare: "report", exec: "ok", cold: "cpu=4 mem_mib=7900 disk_mib=32000" });
    const cold = steps.find((s) => s.step === COLD_CREATE_STEP);
    expect(cold?.status).toBe("pass");
    expect(cold?.detail).toContain("asked 4/8192/32768: cpu=4 mem_mib=7900 disk_mib=32000 listed size=4/8192/32768");
    expect(log).toContain(`create cold size ${JSON.stringify(COLD_CREATE_SIZE)}`);
    expect(log.indexOf("delete cold")).toBeGreaterThan(log.indexOf("exec cold"));
    expect(steps.findIndex((s) => s.step === COLD_CREATE_STEP)).toBeGreaterThan(steps.findIndex((s) => s.step === "first exec"));
    expect(probe.outcome).toBe("ok");
  });

  test("a create the team's machine cap refuses waits for room, each attempt under its own key; other errors and a full budget throw", async () => {
    const full = 'cloud.machine.create: HTTP 200 {"code":"cloud.quota.exceeded","message":"this plan allows 5 active machines"}';
    let clock = 0;
    const pause = async (ms: number) => { clock += ms; };
    const now = () => clock;
    const keys: number[] = [];
    const ok = await createWithRoom(async (n) => { keys.push(n); if (n < 2) throw new Error(full); return "vm"; }, 240_000, pause, now);
    expect(ok).toEqual({ value: "vm", waitedMs: 30_000, refusals: 2 });
    expect(keys).toEqual([0, 1, 2]);
    clock = 0;
    await expect(createWithRoom(async () => { throw new Error(full); }, 60_000, pause, now)).rejects.toThrow(/cloud\.quota\.exceeded.*no room after 60 s, 5 refusals/);
    clock = 0;
    let calls = 0;
    await expect(createWithRoom(async () => { calls++; throw new Error("cloud.machine.create: HTTP 503 cloud.provider.unavailable"); }, 240_000, pause, now)).rejects.toThrow("cloud.provider.unavailable");
    expect(calls).toBe(1);
    expect(await createWithRoom(async () => 1, 240_000, pause, now)).toEqual({ value: 1, waitedMs: 0, refusals: 0 });
  });

  test("a cold machine at the image's size fails the cell, and the checks after it still run", () => {
    const { steps, log } = runJourney({ spare: "report", exec: "ok", cold: "cpu=2 mem_mib=3900 disk_mib=16000" });
    const cold = steps.find((s) => s.step === COLD_CREATE_STEP);
    expect(cold?.status).toBe("fail");
    expect(cold?.detail).toContain("booted at another size than asked: cpu 2 (asked 4)");
    expect(log).toContain("delete cold");
    expect(steps.find((s) => s.step === "machine facts")?.status).not.toBe("fail");
  });
});
