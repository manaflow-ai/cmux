import { describe, expect, test } from "bun:test";
import * as journey from "./cloud-journey";
import { spawnSync } from "node:child_process";
import { existsSync, linkSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { claudeTranscriptModelsProgram, transcriptModels } from "./cloud-journey";
import { ensureBenchCommand, ensureBenchMarkdown, parseEnsureBench } from "./cloud-journey";
import { execProbe, execProbeCommand, execProbeHop, execProbeMarkdown, machineStopFields, markRanOnGuest, EXEC_PROBE_NONCES, type ExecProbeRun } from "./cloud-journey";
import { rpcFailureReason } from "./cloud-journey";
import { Api, clientPlatformOrigin, Journey, preclaimDeployFields, preclaimGuestFacts, preclaimHoldMinutes, preclaimMetMarkdown, preclaimRefillImage, preclaimRefillToReady, runPreclaimBurst, runPreclaimChat, warmSpareRefusal } from "./cloud-journey";
import { saveSendTrace, SEND_TRACE_SETTLE_MS } from "./cloud-journey";
import { startMarks, claudeLoginPrograms, credentialSeen, judgeStubCredentials, launchCredentialStartProgram, loginBearer, loginPathAfterClaim, loginPrograms, MODEL_PLANE_PLACEHOLDER, startsOnLaunchCredential, preclaimPublicMeta, preclaimPublicStep, stubCodexAuth, validLogin, INSTALLER_SWIFT, JOURNEY_STUB_SCRIPT, journeyReadFileCommand, journeyReadPrompt,
  journeyTextPrompt,
  journeyTextReply, MODEL_STUB_PY, newReds, capacityOnly, probeRow, readEnvFile, readyMs, resolveBackend, scrub, summaryMarkdown, swiftRawString, agentReady, milestoneLines, spareTaken } from "./cloud-journey";
import { oidcSignIn, ownerKindGated, startAfterOwnerKind, waitOwnerKind, waitPreflight, CODEX_STUB_CONFIG, OWNER_KIND_GATE_EXIT, OWNER_KIND_PROGRAM, PREFLIGHT_PROBE } from "./cloud-journey";
import { directExec, settleBackground, keyProbeCommand, keyProbeDetail, keyProbeStatus, parseKeyProbe, KEY_PROBE_PY } from "./cloud-journey";
import { deleteJourneyMachines, journeyMachineEligible, leakProof, machineLine, parseDeleteEntries, provenLeak, type MachineScope } from "./cloud-journey";
import { desktopLinkDial, desktopLinkVerdict, maskAddresses, rdFrame, teamIdsIn, RD_FEEDBACK } from "./cloud-journey";
import { carrierScrollProbe, parseScrollReport, scrollDetail, scrollNotes } from "./cloud-journey";
import { sessionModelVerdict } from "./cloud-journey";
import { canonicalKey, carrierDial, carrierTicketProblem, claimToBoundSplit, classifyLeaseHit, cloudSpareReadyFrame, dialDetail, dialPhases, guestTimeline, JOURNAL_FIELD, hopSpans, hopTimes, machineIds, newMachineIds, opaquePreclaimLeaseId, opRetryable, deleteRetryable, requestTimedOut, IDLE_JOURNEY_MS, listAllMachines, listedMachine, preclaimClaimRecord, preclaimFailureRecord, preclaimHealthSnapshot, preclaimLoginMode, preclaimRunComplete, preclaimSummary, preclaimSummaryMarkdown, waitForReadySpare, waitForSpareReady, spareRecordReady, claimTookSpare, anyCloudSpareReady, installTokenTeam, staleJourneyInstalls, staleJourneyMachines, machinesByState, FAILED_JOURNEY_MS, STALE_JOURNEY_MS, LONG_JOURNEY_MS, autoMachineName } from "./cloud-journey";
import { http as journeyHttp, socketDropped } from "./cloud-journey";
import { sameSurgeSlots, surgeMachineIds, SURGE_PROOF_REQUEST } from "./cloud-journey";
import { idleHeldBy, idlePauseDeadlineMs, machineIdleSeconds } from "./cloud-journey";
import { parseClaimedMarkers, parseWarmHomeAnswer } from "./cloud-journey";
import { platformVerdict, waitRunning } from "./cloud-journey";
import { preclaimPhasesText } from "./cloud-journey";
import { OWN_LOGIN_CHECK, preclaimInstallCommand } from "./cloud-journey";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("cloud journey", () => {
  test("a create stuck provisioning with no host waits for the platform's verdict and names it", async () => {
    // Prod journey 45767907054: the journey deleted the machine at 300 s, before the platform's never_bound sweep
    // probed the guest, so no run said why. The rows below are what cloud.machine.get answers, one per read.
    const reads = (rows: unknown[]) => {
      let i = 0;
      return { read: async () => rows[Math.min(i++, rows.length - 1)] } as unknown as Api;
    };
    const stuck = { status: "provisioning", host: null };
    const failed = { status: "failed", host: null, error: { code: "cloud.machine.never_bound" } };
    await expect(waitRunning(reads([stuck, stuck, stuck, failed]), "vm_x", 20, 5_000, 1)).rejects
      .toThrow(/last status provisioning host null; platform verdict cloud\.machine\.never_bound$/);
    await expect(waitRunning(reads([stuck]), "vm_x", 20, 50, 5)).rejects.toThrow(/platform verdict none within \d+ s$/);
    expect(await platformVerdict(reads([stuck, { status: "failed", error: "cloud.machine.create_overdue" }]), "vm_x", 5_000, 1))
      .toBe("cloud.machine.create_overdue");
    expect(await platformVerdict(reads([{ status: "running", host: "h" }]), "vm_x", 5_000, 1)).toBeNull();
    // A machine that has a host but never got to running is not this case: its timeout stands as it was.
    await expect(waitRunning(reads([{ status: "starting", host: "h1" }]), "vm_x", 20, 5_000, 1)).rejects
      .toThrow(/^timed out after 20 ms; last status starting host h1$/);
    expect(await waitRunning(reads([{ status: "running", host: "h2" }]), "vm_x", 5_000, 0)).toEqual({ status: "running", host: "h2" });
  });

  test("a missed idle pause names what held the machine", async () => {
    const api = (row: unknown) => ({ read: async () => row }) as unknown as Api;
    expect(await idleHeldBy(api({ status: "running", last_active_at: null, idle_policy: { idle_seconds: 120 } }), "vm_x", 1_000_000))
      .toBe("idle clock not running (last_active_at null: no report speaks for its activity); idle policy 120 s");
    expect(await idleHeldBy(api({ status: "running", last_active_at: 940_000, idle_policy: { idle_seconds: 120 }, activity: { active_sessions: 1 } }), "vm_x", 1_000_000))
      .toBe('idle clock started 60 s ago; idle policy 120 s; activity {"active_sessions":1}');
    expect(await idleHeldBy(api({ status: "running", last_active_at: 1_000_000, idle_policy: { idle_seconds: 120 }, idle_kept: { why: "workload", running_s: 900, report_age_s: 20, daemon: "1.0.0", workload: { busy: 0, listening: 1, ports: [5173] } } }), "vm_x", 1_000_000))
      .toBe('idle clock started 0 s ago; idle policy 120 s; kept by {"why":"workload","workload":{"busy":0,"listening":1,"ports":[5173]}}');
    const failing = { read: async () => { throw new Error("HTTP 503"); } } as unknown as Api;
    expect(await idleHeldBy(failing, "vm_x")).toBe("idle facts unreadable: HTTP 503");
  });

  test("parses claimed reserved-home markers", () => {
    expect(parseClaimedMarkers(".claimed-surface-2\nnoise\n.claimed-surface-1\n.claimed-surface-2\n")).toEqual([".claimed-surface-1", ".claimed-surface-2"]);
    expect(parseClaimedMarkers("\nno marker\n")).toEqual([]);
  });

  test("parses warm-home answers and unsupported images", () => {
    expect(parseWarmHomeAnswer('{"accepted":true,"state":"ready"}')).toEqual({ state: "ready", reason: "reserved home chat is ready" });
    // acpmux --json pretty-prints (cli/output.rs print_json): prod's stub leg read this as "no JSON answer".
    expect(parseWarmHomeAnswer('{\n  "accepted": true,\n  "state": "ready",\n  "shapes": [\n    {\n      "harness": "claude"\n    }\n  ]\n}\n')).toEqual({ state: "ready", reason: "reserved home chat is ready" });
    expect(parseWarmHomeAnswer('note: dialing\n{\n  "accepted": false,\n  "state": "busy"\n}')).toEqual({ state: "not_ready", reason: "warm-home answered state=busy" });
    expect(parseWarmHomeAnswer('{"accepted":false,"state":"busy"}')).toEqual({ state: "not_ready", reason: "warm-home answered state=busy" });
    // Prod stub run 45848359611: "warm-home answered state=none" said nothing of why; acpmux now names it.
    expect(parseWarmHomeAnswer('{"accepted":true,"state":"none","why":"another key holds its slot (warming), differing in model"}')).toEqual({ state: "not_ready", reason: "warm-home answered state=none (another key holds its slot (warming), differing in model)" });
    expect(parseWarmHomeAnswer("")).toEqual({ state: "unsupported", reason: "warm-home is unavailable on this guest image" });
    expect(parseWarmHomeAnswer("warm-home: command not found")).toEqual({ state: "unsupported", reason: "warm-home returned no JSON answer" });
  });

  test("session model is read from the Claude transcript: a record naming the asked model does not pass a different one", async () => {
    // Production 2026-11-10 (cmux#40383): the second chat's record named Haiku while the pooled agent ran Sonnet.
    const fake = (transcript: string, info = '{"model":"claude-haiku-5-5","agentSessionId":"sid-1"}') => {
      const commands: string[] = [];
      const exec = async (command: string) => {
        commands.push(command);
        return { stdout: command.includes("session info") ? info : transcript, stderr: "", code: 0 };
      };
      return { exec: exec as any, commands };
    };
    const line = (model: string) => `"model":"${model}"\n`;
    const ok = fake(line("claude-haiku-5-5") + line("<synthetic>"));
    expect(await sessionModelVerdict(ok.exec, "s-m2", "claude-haiku-5-5")).toBe("asked claude-haiku-5-5; the agent ran claude-haiku-5-5 (its Claude transcript)");
    expect(ok.commands[1]).toContain("sid-1");
    expect(await sessionModelVerdict(fake(line("claude-haiku-5-5-20261101")).exec, "s-m2", "claude-haiku-5-5")).toContain("claude-haiku-5-5-20261101");
    await expect(sessionModelVerdict(fake(line("claude-sonnet-5-5")).exec, "s-m2", "claude-haiku-5-5")).rejects.toThrow("the agent ran claude-sonnet-5-5");
    await expect(sessionModelVerdict(fake(line("claude-haiku-5-5") + line("claude-sonnet-5-5")).exec, "s-m2", "claude-haiku-5-5")).rejects.toThrow("claude-sonnet-5-5");
    await expect(sessionModelVerdict(fake("").exec, "s-m2", "claude-haiku-5-5")).rejects.toThrow("names no model");
    await expect(sessionModelVerdict(fake("", '{"model":"claude-haiku-5-5"}').exec, "s-m2", "claude-haiku-5-5")).rejects.toThrow("no agentSessionId");
  });

  test("the default idle walk waits out the machine's own policy, not 900 s", async () => {
    const api = (row: unknown) => ({ read: async () => row }) as unknown as Api;
    expect(await machineIdleSeconds(api({ idle_policy: { idle_seconds: 1800 } }), "vm_x")).toBe(1800);
    expect(await machineIdleSeconds(api({ idle_seconds: 120 }), "vm_x")).toBe(120);
    expect(await machineIdleSeconds(api({}), "vm_x")).toBeNull();
    expect(idlePauseDeadlineMs(1800, 600)).toBe(2_100_000);
    expect(idlePauseDeadlineMs(120, 600)).toBe(900_000);
    // A record with both fields: the top-level idle_seconds wins.
    expect(await machineIdleSeconds(api({ idle_seconds: 120, idle_policy: { idle_seconds: 1800 } }), "vm_x")).toBe(120);
    // No policy fails at once instead of waiting out the 24 h backstop.
    expect(() => idlePauseDeadlineMs(null, 600)).toThrow(/names no idle policy/);
  });

  test("preclaim table survives the enclosing journey step on success and failure", async () => {
    for (const fail of [false, true]) {
      const out = mkdtempSync(join(tmpdir(), "preclaim-summary-test-"));
      try {
        const journey = new Journey(resolveBackend("staging"), out, { account: "private-account" }, true);
        const row = preclaimClaimRecord({ claim: 1, machine: "private-machine", leaseHit: true, firstReplyMs: 27 });
        const burst = journey.step("preclaim burst", async () => {
          Object.assign(journey, { preclaimRows: [row] });
          journey.flush();
          if (fail) throw new Error("private failure detail");
          return { value: 0, detail: "private step detail" };
        });
        if (fail) await expect(burst).rejects.toThrow("private failure detail");
        else await burst;
        journey.flush();
        const summary = readFileSync(join(out, "summary.md"), "utf8");
        expect(summary).toContain(preclaimSummaryMarkdown([row]));
        expect(summary).toContain("preclaim burst");
        expect(summary).not.toContain("private-");
        expect(summary).not.toContain("private failure detail");
        expect(summary).not.toContain("private step detail");
      } finally {
        rmSync(out, { recursive: true, force: true });
      }
    }
  });

  test("preclaim reply waits through idle before a queued prompt starts", async () => {
    const replies = ["@@exit 0", "@@exit 0", "@@wait 0\n", "@@wait 0\nThe measured reply."];
    const commands: string[] = [];
    const result = await runPreclaimChat(async (command) => {
      commands.push(command);
      const stdout = replies.shift();
      if (stdout === undefined) throw new Error("unexpected extra command");
      return { code: 0, stdout, stderr: "" };
    }, "fixture-session", "Reply once", 1000);
    expect(commands).toHaveLength(4);
    expect(replies).toEqual([]);
    expect(result.replyMs).toBeGreaterThanOrEqual(0);
  });

  test("preclaim records preserve the claim-to-bound split and receipt state", () => {
    const row = preclaimClaimRecord({
      claim: 2,
      spare: "vm_spare",
      answer: {
        machine_id: "vm_claim",
        lease_hit: true,
        stages_ms: [
          { step: "machine", ms: 40 },
          { step: "join", ms: 12 },
          { step: "guest_bind", ms: 8 },
          { step: "connect_info", ms: 10 },
          { step: "bound", ms: 5 },
        ],
      },
      postBindLogin: "receipt",
    });
    expect(row).toEqual({
      claim: 2,
      machine: "vm_claim",
      spare: "vm_spare",
      lease_id: null,
      lease_hit: true,
      health_before: { http_status: 0, outcome: "error", commit: null, commit_unavailable: "not read" },
      health_after: { http_status: 0, outcome: "error", commit: null, commit_unavailable: "not read" },
      platform_health_before: { http_status: 0, outcome: "error", commit: null, commit_unavailable: "not read" },
      platform_health_after: { http_status: 0, outcome: "error", commit: null, commit_unavailable: "not read" },
      claim_to_bound: { claim_answer_ms: 40, join_ms: 52, guest_bind_ms: 60, connect_info_ms: 70, bound_ms: 75 },
      post_bind_login: "receipt",
      first_chat_ms: null,
      first_reply_ms: null,
      warm_team_matches_claim: null,
      warm_named: true,
      warm_reason: null,
      spare_ready_by: null,
      refill_to_ready_ms: null, refill_to_ready_unavailable: "not recorded", refill_image: null, refill_image_unavailable: "not recorded",
      post_bind_login_ms: null, post_bind_login_ms_unavailable: "not recorded", claim_to_first_text_ms: null, claim_to_first_text_unavailable: "not recorded",
      staging_sha: null, staging_sha_unavailable: "platform: not read; api: not read",
      deploy_overlap: null, deploy_overlap_unavailable: "no service's /v1/health named a deploy commit both before and after the claim",
      reply_not_judged: null,
      spare_wait_ms: null,
      cold_after_wait: false,
      claimed_behind: null,
      spare_skips: null,
      spare_fallback: null,
    });
  });

  test("a bounded wait for a ready spare retries until the warm names one, and reports the wait", async () => {
    let t = 0;
    const answers = [null, null, "vm_spare"];
    const sleeps: number[] = [];
    const out = await waitForReadySpare(async () => ({ spare: answers.shift() ?? null }), 120_000, { pollMs: 15_000, now: () => t, sleep: async (ms) => { sleeps.push(ms); t += ms; } });
    expect(out.prepared.spare).toBe("vm_spare");
    expect(out.wait).toEqual({ waited_ms: 30_000, attempts: 3, cold_after_wait: false, ready_by: "warm" });
    expect(sleeps).toEqual([15_000, 15_000]);
  });

  test("a wait that runs out claims anyway and marks the claim cold after the wait; no wait asks once", async () => {
    let t = 0;
    let calls = 0;
    const out = await waitForReadySpare(async () => { calls++; return { spare: null }; }, 40_000, { pollMs: 15_000, now: () => t, sleep: async (ms) => { t += ms; } });
    expect(out.prepared.spare).toBeNull();
    expect(out.wait).toEqual({ waited_ms: 30_000, attempts: 3, cold_after_wait: true, ready_by: null });
    expect(calls).toBe(3);
    calls = 0;
    const once = await waitForReadySpare(async () => { calls++; return { spare: null }; }, 0);
    expect(once.wait).toBeNull();
    expect(calls).toBe(1);
  });

  test("the wait ends when the claim path reports a ready spare the warm did not name, and says so", async () => {
    // Burst 43951741299: the warm named no spare for 300 s before 9 of 9 claims, and 7 of those claims took a ready spare.
    let t = 0;
    const listened: number[] = [];
    const seen = [null, "vm_Ready0123456789"];
    const out = await waitForReadySpare(async () => ({ spare: null }), 120_000, {
      pollMs: 15_000, now: () => t, sleep: async () => { throw new Error("a claim-path probe replaces the sleep"); },
      ready: async (ms) => { listened.push(ms); t += ms; return seen.shift() ?? null; },
    });
    expect(out.prepared.spare).toBeNull();
    expect(out.wait).toEqual({ waited_ms: 30_000, attempts: 2, cold_after_wait: false, ready_by: "claim_path" });
    expect(listened).toEqual([15_000, 15_000]);
  });

  test("a hit is read from the claim answer: a claim object and no fallback, whatever the warm named", () => {
    expect(claimTookSpare({ machine: { id: "vm_x" }, claim: { behind: false } })).toBe(true);
    expect(claimTookSpare({ machine: { id: "vm_x" }, claim: { behind: true }, spare_skips: { image: 1 } })).toBe(true);
    expect(claimTookSpare({ machine: { id: "vm_x" }, spare_fallback: "no_spare", spare_skips: {} })).toBe(false);
    expect(claimTookSpare({ machine: { id: "vm_x" }, claim: { behind: false }, spare_fallback: "all_skipped" })).toBe(false);
    expect(claimTookSpare({ machine: { id: "vm_x" } })).toBeNull();
    const taken = preclaimClaimRecord({ claim: 0, machine: "vm_x", answer: { claim: { behind: false } }, warmNamed: false, warmReason: "spare.none", spareWait: { waited_ms: 15_000, attempts: 2, cold_after_wait: false, ready_by: "claim_path" } });
    expect(taken).toMatchObject({ lease_hit: true, warm_named: false, warm_reason: "spare.none", spare_ready_by: "claim_path" });
    const named = preclaimClaimRecord({ claim: 1, machine: "vm_y", spare: "vm_y", answer: { claim: { behind: false } }, spareWait: { waited_ms: 0, attempts: 1, cold_after_wait: false, ready_by: "warm" } });
    expect(named).toMatchObject({ lease_hit: true, warm_named: true, warm_reason: null, spare_ready_by: "warm" });
    const cold = preclaimClaimRecord({ claim: 2, machine: "vm_z", answer: { spare_fallback: "no_spare" }, warmNamed: false, warmReason: "vm_private id" });
    expect(cold).toMatchObject({ lease_hit: false, warm_named: false, warm_reason: null });
    expect(preclaimSummary([taken, named, cold])).toMatchObject({ lease_hits: 2, lease_misses: 1, claim_taken: 2, warm_named: 1, warm_missed_hits: 1 });
    const md = preclaimSummaryMarkdown([taken, named, cold]);
    expect(md).toContain("- claim took a spare (from the claim answer): 2");
    expect(md).toContain("- warm named a spare: 1");
    expect(md).toContain("- hits the warm did not name (no login attached in advance): 1");
    expect(md).toContain("| warm named |");
  });

  test("the claim path's ready spare: a cloud.spare.ready frame or a snapshot's spares_needing_login on the team's stream", () => {
    const team = "team_0123456789abcdef0123";
    expect(anyCloudSpareReady({ t: "ephemeral", stream: `cloud:${team}`, event: "cloud.spare.ready", data: { machine: "vm_A1234567", team } }, team)).toBe("vm_A1234567");
    expect(anyCloudSpareReady({ t: "snapshot", stream: `cloud:${team}`, spares_needing_login: ["vm_B1234567"] }, team)).toBe("vm_B1234567");
    expect(anyCloudSpareReady({ t: "snapshot", stream: `cloud:${team}`, spares_needing_login: [] }, team)).toBeNull();
    expect(anyCloudSpareReady({ t: "ephemeral", stream: "cloud:team_other0123456789", event: "cloud.spare.ready", data: { machine: "vm_C1234567" } }, team)).toBeNull();
    expect(anyCloudSpareReady({ t: "ephemeral", stream: `cloud:${team}`, event: "cloud.machine.updated", data: { machine: "vm_D1234567" } }, team)).toBeNull();
  });

  test("cold creates after a ready spare was reported count apart from claims made after the wait ran out", () => {
    const rows = [
      preclaimClaimRecord({ claim: 0, leaseHit: true, spareWait: { waited_ms: 15_000, attempts: 2, cold_after_wait: false } }),
      preclaimClaimRecord({ claim: 1, leaseHit: false, spareWait: { waited_ms: 300_000, attempts: 21, cold_after_wait: true } }),
      preclaimClaimRecord({ claim: 2, leaseHit: false, spare: "vm_spare", spareWait: { waited_ms: 0, attempts: 1, cold_after_wait: false } }),
    ];
    expect(rows[0].spare_wait_ms).toBe(15_000);
    expect(rows[1].cold_after_wait).toBe(true);
    expect(preclaimSummary(rows)).toMatchObject({ lease_misses: 2, cold_creates: 1, cold_after_wait: 1, spare_wait_p90_ms: 300_000 });
    const md = preclaimSummaryMarkdown(rows);
    expect(md).toContain("- cold creates: 1");
    expect(md).toContain("- cold after the ready-spare wait ran out: 1");
    expect(md).toContain("| spare wait |");
    expect(md).toContain("| 300000 (ran out) |");
  });

  test("preclaim records name a claim served one image roll behind (held across a roll) and the claim's skips", () => {
    const held = preclaimClaimRecord({ claim: 0, answer: { claim: { behind: true }, spare_skips: { image: 2, "vm_private id": 1 }, spare_fallback: "image" } });
    expect(held.claimed_behind).toBe(true);
    expect(held.spare_skips).toEqual({ image: 2 });
    expect(held.spare_fallback).toBe("image");
    const current = preclaimClaimRecord({ claim: 1, answer: { claim: { behind: false } } });
    expect(current.claimed_behind).toBe(false);
    expect(preclaimClaimRecord({ claim: 2, answer: { machine_id: "vm_cold" } }).claimed_behind).toBeNull();
  });

  test("the preclaim summary counts held claims and their failures apart from normal hits", () => {
    const ok = { postBindLogin: "receipt" as const, firstChatMs: 5, firstReplyMs: 9 };
    const rows = [
      preclaimClaimRecord({ claim: 0, leaseHit: true, answer: { claim: { behind: false }, spare_skips: { image: 1 } }, ...ok }),
      preclaimClaimRecord({ claim: 1, leaseHit: true, answer: { claim: { behind: true } }, ...ok }),
      preclaimClaimRecord({ claim: 2, leaseHit: true, answer: { claim: { behind: true }, spare_skips: { image: 3, disconnected: 1 } }, postBindLogin: "receipt", firstChatMs: 5, firstReplyMs: null }),
      // Claim 2 got no reply but its login arrived: the reply is never judged, so it is not a held failure.
      preclaimClaimRecord({ claim: 3, leaseHit: false, answer: { spare_fallback: "image", spare_skips: { image: 2 } }, postBindLogin: "post-bind", firstReplyMs: 40 }),
    ];
    const failures = [preclaimFailureRecord(4, new Error("reply wait exit 1"), [], true), preclaimFailureRecord(5, new Error("create refused"))];
    expect(failures[0].claimed_behind).toBe(true);
    expect(failures[1].claimed_behind).toBeNull();
    const summary = preclaimSummary(rows, failures);
    expect(summary).toMatchObject({ claims: 4, lease_hits: 3, lease_misses: 1, cold_creates: 1, held_claims: 3, held_failures: 1, image_skips: 6, claims_with_image_skip: 3 });
    const md = preclaimSummaryMarkdown(rows, failures);
    expect(md).toContain("- held claims (one image roll behind): 3");
    expect(md).toContain("- held claim failures: 1");
    expect(md).toContain("- cold creates: 1");
    expect(md).toContain("| held |");
    expect(md).not.toContain("reply wait exit 1");
  });

  test("preclaim health and lease evidence stay bounded and opaque", () => {
    expect(opaquePreclaimLeaseId("lease-secret-value")).toMatch(/^lease:[0-9a-f]{12}$/);
    expect(opaquePreclaimLeaseId("lease-secret-value")).not.toContain("secret");
    expect(preclaimHealthSnapshot({ status: 200, body: { commit: "c684eb73", account: "other-account" } })).toEqual({ http_status: 200, outcome: "ok", commit: "c684eb73", commit_unavailable: null });
    const row = preclaimClaimRecord({ claim: 1, leaseId: "lease:opaque", healthBefore: { http_status: 200, outcome: "ok", commit: "a", commit_unavailable: null }, healthAfter: { http_status: 200, outcome: "ok", commit: "b", commit_unavailable: null }, firstChatMs: 11, firstReplyMs: 22 });
    expect(row.lease_id).toBe("lease:opaque");
    expect(row.machine).toBeNull();
    expect(row.health_before.commit).toBe("a");
    expect(row.first_reply_ms).toBe(22);
    const publicText = preclaimSummaryMarkdown([preclaimClaimRecord({ claim: 1, machine: "vm_private", spare: "vm_spare", leaseId: "lease:opaque", leaseHit: true, firstChatMs: 11, firstReplyMs: 22 })]);
    expect(publicText).toContain("lease:opaque");
    expect(publicText).toContain("11");
    expect(publicText).not.toContain("vm_private");
    expect(publicText).not.toContain("vm_spare");
  });

  test("preclaim public journey output drops setup identifiers", () => {
    const safe = preclaimPublicStep({ step: "user.ensure", status: "pass", ms: 17, detail: "user user_secret install install_secret" });
    expect(safe).toEqual({ step: "user.ensure", status: "pass", ms: 17, detail: "pass" });
    const md = summaryMarkdown(resolveBackend("staging"), [safe], preclaimPublicMeta());
    expect(md).toContain("mode: preclaim");
    expect(md).not.toContain("user_secret");
    expect(md).not.toContain("install_secret");
  });

  test("the preclaim install, cleanup and own-login check run as one exec", () => {
    const dir = mkdtempSync(join(tmpdir(), "preclaim-"));
    const run = (install: string, after = "") => {
      const file = join(dir, "cred.json");
      writeFileSync(file, "{}");
      const r = spawnSync("bash", ["-c", preclaimInstallCommand(install, file, after)], { encoding: "utf8" });
      return { code: r.status, out: r.stdout, left: existsSync(file) };
    };
    // A heredoc installer like loginPrograms' keeps its terminator on a line of its own.
    expect(run("set -e\ncat <<'EOF'\ninstalled\nEOF", "echo own-login")).toEqual({ code: 0, out: "installed\nown-login\n", left: false });
    // A refused install keeps its exit, removes the file, and skips the check.
    expect(run("set -e\nfalse\necho never", "echo own-login")).toEqual({ code: 1, out: "", left: false });
    expect(run("exit 3")).toEqual({ code: 3, out: "", left: false });
    expect(OWN_LOGIN_CHECK).toContain("echo own-login");
  });

  test("the preclaim step names where its time went, phase by phase", () => {
    expect(preclaimPhasesText(undefined)).toBe("");
    expect(preclaimPhasesText({})).toBe("");
    expect(preclaimPhasesText({ warm: 812, ready_wait: 6101, install: 2400 })).toBe("; phases: warm 812 ms, ready_wait 6101 ms, install 2400 ms");
  });

  test("cold preclaim claims use the post-bind login fallback before chat", () => {
    expect(preclaimLoginMode(null, "cold-machine")).toBe("post-bind");
    expect(preclaimLoginMode("ready-spare", "ready-spare")).toBe("preclaim");
    expect(preclaimLoginMode("ready-spare", "different-claimed-machine")).toBe("post-bind");
  });

  test("preclaim failures retain a private failed row and force a nonzero incomplete run", () => {
    const failure = preclaimFailureRecord(3, new Error("credential installer refused: secret-value"), ["secret-value"]);
    expect(failure).toEqual({ claim: 3, outcome: "fail", error: "credential installer refused: [secret]", claimed_behind: null });
    expect(preclaimRunComplete([], [failure], 1)).toBe(false);
    expect(preclaimRunComplete([preclaimClaimRecord({ claim: 0 })], [], 1)).toBe(true);
  });

  test("lease classification uses explicit broker evidence and keeps unknown separate from a miss", () => {
    expect(classifyLeaseHit({ lease_hit: false })).toBe(false);
    expect(classifyLeaseHit({ source: "warm" })).toBe(true);
    expect(classifyLeaseHit({}, "claim lease_hit=no")).toBe(false);
    expect(classifyLeaseHit({ message: "claimed spare" }, "claimed spare")).toBeNull();
    expect(classifyLeaseHit({ machine_id: "vm_cold" })).toBeNull();
  });

  test("preclaim waits only for the owner's team stream and accepts its replayed ready event", () => {
    expect(cloudSpareReadyFrame({ event: "cloud.spare.ready", stream: "cloud:team_a", data: { machine: "vm_spare", team: "team_a" } }, "vm_spare", "team_a")).toBe(true);
    expect(cloudSpareReadyFrame({ event: "cloud.spare.ready", stream: "cloud:team_b", data: { machine: "vm_spare", team: "team_b" } }, "vm_spare", "team_a")).toBe(false);
    expect(cloudSpareReadyFrame({ t: "snapshot", stream: "cloud:team_a", spares_needing_login: ["vm_spare"] }, "vm_spare", "team_a")).toBe(true);
    expect(cloudSpareReadyFrame({ event: "cloud.spare.ready", stream: "cloud:team_a", data: { machine: "vm_other", team: "team_a" } }, "vm_spare", "team_a")).toBe(false);
  });

  test("claim stage extraction accepts the cloud start-session steps object without inventing missing stages", () => {
    expect(claimToBoundSplit({ steps: [{ step: "claim", ms: 10 }, { step: "bound", ms: 5 }] })).toEqual({ claim_answer_ms: 10, join_ms: null, guest_bind_ms: null, connect_info_ms: null, bound_ms: 15 });
    expect(claimToBoundSplit(undefined)).toEqual({ claim_answer_ms: null, join_ms: null, guest_bind_ms: null, connect_info_ms: null, bound_ms: null });
  });

  test("--sign-in oidc trades the job's OIDC token for the API's session and keeps both out of the output", async () => {
    const calls: Array<{ method: string; url: string; auth: string }> = [];
    const fake = async (method: string, url: string, _body: unknown, headers: Record<string, string>) => {
      calls.push({ method, url, auth: headers.authorization ?? "" });
      if (url.startsWith("https://gh.example/token")) return { status: 200, body: { value: "gh-oidc-jwt-value" } };
      return { status: 200, body: { access_token: "stack-access-value", user: "user_x", session_expires_at: "2026-11-04T18:00:00.000Z" } };
    };
    const secrets: string[] = [];
    const s = await oidcSignIn("https://cloud-api.cmux.dev", { ACTIONS_ID_TOKEN_REQUEST_URL: "https://gh.example/token?x=1", ACTIONS_ID_TOKEN_REQUEST_TOKEN: "request-bearer" }, secrets, fake as never);
    expect(s).toEqual({ token: "stack-access-value", user: "user_x", expiresAt: "2026-11-04T18:00:00.000Z" });
    expect(calls[0]).toEqual({ method: "GET", url: "https://gh.example/token?x=1&audience=https%3A%2F%2Fcloud-api.cmux.dev", auth: "bearer request-bearer" });
    expect(calls[1]).toEqual({ method: "POST", url: "https://cloud-api.cmux.dev/v1/auth/github-actions", auth: "Bearer gh-oidc-jwt-value" });
    expect(secrets).toEqual(["request-bearer", "gh-oidc-jwt-value", "stack-access-value"]);
    // What the journey renders goes through scrub with that list: none of the three survives.
    const rendered = scrub(`GET bearer request-bearer -> gh-oidc-jwt-value; session stack-access-value`, secrets);
    for (const v of secrets) expect(rendered).not.toContain(v);
    await expect(oidcSignIn("https://cloud-api.cmux.dev", {}, [], fake as never)).rejects.toThrow("id-token: write");
    const refused = async () => ({ status: 401, body: { error: "this token is not trusted to sign in", value: "gh-oidc-jwt-value" } });
    await expect(oidcSignIn("https://cloud-api.cmux.dev", { ACTIONS_ID_TOKEN_REQUEST_URL: "https://gh.example/t", ACTIONS_ID_TOKEN_REQUEST_TOKEN: "rb" }, [], refused as never)).rejects.toThrow("GitHub OIDC token HTTP 401");
    // The API's two refusals of a correct job say what to change (cmux#35703).
    const ghOk = (status: number) => async (_m: string, url: string) => (url.startsWith("https://gh.example/") ? { status: 200, body: { value: "gh-oidc-jwt-value" } } : { status, body: {} });
    const env = { ACTIONS_ID_TOKEN_REQUEST_URL: "https://gh.example/t", ACTIONS_ID_TOKEN_REQUEST_TOKEN: "rb" };
    await expect(oidcSignIn("https://cloud-api.cmux.dev", env, [], ghOk(404) as never)).rejects.toThrow("has no POST /v1/auth/github-actions yet");
    await expect(oidcSignIn("https://cloud-api.cmux.dev", env, [], ghOk(401) as never)).rejects.toThrow("no valid CI_SESSION_TRUST row matches it");
  });
  test("backend names map to the cmux API Worker of each environment", () => {
    expect(resolveBackend("staging").api).toBe("https://cloud-api-staging.cmux.dev");
    expect(resolveBackend("prod")).toEqual({ name: "prod", api: "https://cloud-api.cmux.dev", stack: "prod" });
    expect(resolveBackend("preview-35100").api).toBe("https://cmux-api-preview-35100.debussy.workers.dev");
    expect(resolveBackend("preview-leo1").stack).toBe("dev");
    expect(resolveBackend("local", undefined, undefined, 9000).api).toBe("http://127.0.0.1:9000");
    expect(resolveBackend("custom", "https://x.example/", "prod")).toEqual({ name: "custom", api: "https://x.example", stack: "prod" });
    expect(() => resolveBackend("classic")).toThrow();
    expect(() => resolveBackend("preview-A_B")).toThrow();
  });
  test("secrets never reach the output", () => {
    const out = scrub("token eyJabcdefghijk.payload Bearer abc cmuxvm_sk_0123456789 pw hunter22", ["hunter22"]);
    expect(out).not.toContain("eyJabcdefghijk");
    expect(out).not.toContain("cmuxvm_sk_0123456789");
    expect(out).not.toContain("hunter22");
    expect(out).not.toMatch(/Bearer abc/);
  });

  test("scrub keeps serialized JSON parseable: a 401's \"bearer token\" eats no quote (run 45510772491)", () => {
    const cycle = { error: `cloud.machine.start: HTTP 401 ${JSON.stringify({ code: "auth.unauthenticated", message: "missing or invalid bearer token" })}`, at: "x" };
    const out = scrub(JSON.stringify({ cycles: [cycle] }, null, 2));
    expect(JSON.parse(out).cycles[0].at).toBe("x");
    expect(scrub(JSON.stringify({ h: "Bearer abc.def-ghi" }))).toBe('{"h":"[secret]"}');
  });
  test("env files and the summary table", () => {
    expect(readEnvFile("export A='1'\nB=\"two\"\n# c\n")).toEqual({ A: "1", B: "two" });
    const md = summaryMarkdown(resolveBackend("staging"), [
      { step: "health", status: "pass", ms: 10, detail: "a|b" },
      { step: "reply", status: "fail", ms: 5, detail: "x" },
    ]);
    expect(md.startsWith("FAIL")).toBe(true);
    expect(md).toContain("| **FAIL** | reply | 5 | x |");
    expect(md).toContain("a\\|b");
  });

  test("a carrier dial's detail keeps its phases in the summary, up to 1000 characters", () => {
    const phases = Array.from({ length: 8 }, (_, i) => `reconnect relay: ticket 300, relay ${15_000 + i}, parked 0, handshake 0, mux 0 ms, lanes 0, ${15_300 + i} ms`);
    const detail = dialDetail({ connectMs: 640, replyMs: 900, retries: 5, failed: [], phases, reply: "{}" });
    expect(detail.length).toBeGreaterThan(600);
    const md = summaryMarkdown(resolveBackend("staging"), [{ step: "connect (carrier dial)", status: "pass", ms: 900, detail }]);
    expect(md).toContain(phases[7]);
  });

  test("newReds: only steps the deploy turned red", () => {
    const st = (step: string, status: "pass" | "fail" | "skip") => ({ step, status, ms: 1, detail: "" });
    const before = [st("health", "pass"), st("create machine", "pass"), st("running (status)", "fail")];
    const after = [st("health", "fail"), st("create machine", "pass"), st("running (status)", "fail")];
    // running (status) was already red before the deploy (a known bug): not a rollback.
    expect(newReds(before, after).map((s) => s.step)).toEqual(["health"]);
    expect(newReds(before, [st("health", "pass"), st("running (status)", "fail")])).toEqual([]);
    // No baseline: every failed step counts.
    expect(newReds(null, after).map((s) => s.step)).toEqual(["health", "running (status)"]);
  });
  test("capacityOnly: no machine or a rate limit is never the deploy's red", () => {
    const red = (detail: string) => ({ step: "create machine", status: "fail" as const, ms: 1, detail });
    expect(capacityOnly([red("POST /v1/cloud/machines: HTTP 429 Too Many Requests")])).toBe(true);
    expect(capacityOnly([red("no machine available in any region"), red("rate limited, retry after 30 s")])).toBe(true);
    // A machine given and then broken is the build's: vm_unavailable on its first exec, a crash, a timeout.
    expect(capacityOnly([red("the machine did not take its first exec (vm_unavailable)")])).toBe(false);
    expect(capacityOnly([red("HTTP 429"), red("reply timed out")])).toBe(false);
    expect(capacityOnly([])).toBe(false);
    // The journey's own capacity codes: a full team before the first create, a create refused at the cap.
    expect(capacityOnly([red("cloud.quota.headroom quota_headroom:account-team used 5/5, need 2 (no room after 244 s, 17 reads)")])).toBe(true);
    expect(capacityOnly([red("cloud.quota.exceeded: at the cap (no room after 60 s, 5 refusals)")])).toBe(true);
    expect(capacityOnly([red("cloud.quota.headroom quota_headroom:t used 5/5, need 2"), red("reply timed out")])).toBe(false);
    // The provider refusing to make a machine (run 46010808734's cold create), not a given machine breaking.
    expect(capacityOnly([red('machine failed: {"error":{"code":"cloud.machine.create_overdue","message":"the machine\'s create did not settle within 300 s (6 failed tries, the last cloud.provider.unavailable: VM API: HTTP 503: ServiceUnavailable (vm-provider.createQueueFull))"}}')])).toBe(true);
    expect(capacityOnly([red("FreestyleApiError: infrastructure overloaded: VM start capacity queue wait expired")])).toBe(true);
    expect(capacityOnly([red("cloud.provider.unavailable"), red('exec: HTTP 502 "vm_unavailable"')])).toBe(false);
  });
  test("the login copy runs the Mac installer's own programs", () => {
    expect(swiftRawString('  static let x = #"""\n      a\n        b\n      """#', "x")).toBe("a\n  b");
    const programs = claudeLoginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"));
    expect(programs.preflight.startsWith("set -eu\n")).toBe(true);
    expect(programs.preflight).toContain("/etc/cmux/vm-kind");
    const install = programs.install("/home/cmux/.cmux/credential-transfer/A.json");
    expect(install).toContain("python3 - 'claude' '/home/cmux/.cmux/credential-transfer/A.json' owner <<'CMUX_CREDENTIAL_INSTALL'\nimport json, os");
    expect(install).toContain("env['CLAUDE_CODE_OAUTH_TOKEN'] = value");
    expect(install.endsWith("\nCMUX_CREDENTIAL_INSTALL")).toBe(true);
  });
  test("a run is one probe row", () => {
    const at = new Date("2026-11-04T11:00:00.123Z");
    const ok = probeRow("cloud-chat-replies-production", [
      { step: "send chat", status: "pass", ms: 800, detail: "" },
      { step: "reply", status: "pass", ms: 4200, detail: "Earth." },
    ], "https://x/runs/1", at);
    expect(ok).toEqual({ probe: "cloud-chat-replies-production", at: "2026-11-04T11:00:00Z", runner: "github-actions", run: "https://x/runs/1", outcome: "ok", ms: 5000 });
    const bad = probeRow("p", [{ step: "create machine", status: "fail", ms: 5, detail: "HTTP 503" }], undefined, at);
    expect(bad).toMatchObject({ outcome: "fail", error: "create machine: HTTP 503" });
  });
  test("create machine to agent running is the sum of its steps, only when each passed", () => {
    const at = new Date("2026-11-04T11:00:00Z");
    const st = (step: string, ms: number, status: "pass" | "fail" | "skip" = "pass") => ({ step, status, ms, detail: "" });
    const steps = [st("health", 9), st("create machine", 16500), st("running (status)", 2700), st("first exec", 3000), st("pass Claude login", 10900), st("start agent (claude)", 3700), st("send chat", 800), st("reply", 4200)];
    expect(readyMs(steps)).toBe(36800);
    expect(probeRow("p", steps, undefined, at)).toMatchObject({ outcome: "ok", ms: 5000, ready_ms: 36800 });
    expect(summaryMarkdown(resolveBackend("staging"), steps).split("\n")[0]).toContain("; create machine to agent running 36.8 s");
    // A skipped login copy (no login given) or a failed step is not a comparable total.
    expect(readyMs(steps.map((s) => (s.step === "pass Claude login" ? { ...s, status: "skip" as const } : s)))).toBeNull();
    expect(readyMs(steps.filter((s) => s.step !== "first exec"))).toBeNull();
    expect(probeRow("p", [st("create machine", 5, "fail")], undefined, at)).not.toHaveProperty("ready_ms");
  });
  test("agent_ready_ms is labeled warm or cold and the summary reports M17, G1 warm and M3 without failing the run", () => {
    const at = new Date("2026-11-04T11:00:00Z");
    const st = (step: string, ms: number, status: "pass" | "fail" | "skip" = "pass") => ({ step, status, ms, detail: "" });
    // Production run 45100377818: create 4037 + login 1503 + start agent 1980, send 4118 + reply 959.
    const steps = [st("create machine", 4037), st("running (status)", 0), st("first exec", 0), st("pass Claude login", 1503), st("start agent (claude)", 1980), st("send chat", 4118), st("reply", 959)];
    expect(spareTaken({ spare_fallback: "none_ready" })).toBe(false);
    expect(spareTaken({ spare_fallback: null, claimed_behind: false })).toBe(true);
    expect(spareTaken({ claimed_spare: null })).toBeNull();
    expect(agentReady(steps, true)).toEqual({ agent_ready_ms: 7520, agent_ready_path: "warm", first_reply_ms: 5077 });
    expect(milestoneLines(steps, true)).toEqual([
      "agent_ready_ms: 7520 (warm); first_reply_ms: 5077",
      "- M17 click to agent ready, warm: fail (7520 ms, <= 1000 ms)",
      "- G1 first reply, warm: fail (5077 ms, < 3000 ms)",
      "- M3 agent started step: pass (1980 ms, <= 4000 ms)",
    ]);
    expect(milestoneLines(steps, false)[1]).toBe("- M17 click to agent ready, warm: not judged: a cold start");
    expect(milestoneLines(steps, null)[2]).toBe("- G1 first reply, warm: not judged: a warm-or-cold unknown start");
    const md = summaryMarkdown(resolveBackend("staging"), steps, {}, true);
    expect(md.split("\n")[0]).toMatch(/^PASS: /);
    expect(md).toContain("- M3 agent started step: pass (1980 ms, <= 4000 ms)");
    expect(probeRow("p", steps, undefined, at, undefined, { spare_fallback: null, claimed_behind: false })).toMatchObject({ outcome: "ok", agent_ready_ms: 7520, agent_ready_path: "warm" });
  });
  test("the journey's stub script is valid for the shared model stub and its reply repeats the tool output", () => {
    expect(readFileSync(MODEL_STUB_PY, "utf8")).toContain("--ready-file");
    expect(JOURNEY_STUB_SCRIPT.steps[0].shell).not.toContain("{{nonce}}-tool");
    expect(JOURNEY_STUB_SCRIPT.steps[1].text).toContain("{{result.0}}");
    expect(JOURNEY_STUB_SCRIPT.turns).toEqual(expect.arrayContaining([
      { match: "\\[chaos-felt \\S+\\]", steps: [{ text: "Felt reply {{prompt}}." }] },
    ]));
  });
  test("the reserved home chat's stub turn is a Read in the chat's folder, never a shell call (policy ask holds shell)", () => {
    // Prod run 45585084079: the reserved chat runs under policy `ask`, the default turn's shell call waited on a permission.
    const dir = mkdtempSync(join(tmpdir(), "journey-read-"));
    try {
      const w = spawnSync("bash", ["-c", journeyReadFileCommand(dir, "3bde18dfd6b9")], { encoding: "utf8" });
      const file = /@@file (\S+)/.exec(w.stdout)?.[1] ?? "";
      expect(file).toBe(`${dir}/.journey-3bde18dfd6b9.txt`);
      expect(readFileSync(file, "utf8")).toBe("3bde18dfd6b9-tool\n");
      const script = join(dir, "script.json");
      writeFileSync(script, JSON.stringify(JOURNEY_STUB_SCRIPT));
      // The shared stub itself plays the turn: Claude Code's Read result numbers its lines.
      const play = `
import json, sys, urllib.request
sys.path.insert(0, sys.argv[1])
import model_stub
server, _ = model_stub.serve(json.load(open(sys.argv[2])), "3bde18dfd6b9")
base = f"http://127.0.0.1:{server.server_address[1]}/v1/messages"
ask = lambda msgs: json.loads(urllib.request.urlopen(urllib.request.Request(base, data=json.dumps({"messages": msgs, "tools": [{"name": "Bash"}, {"name": "Read"}]}).encode(), headers={"content-type": "application/json"})).read())["content"][0]
turn = [{"role": "user", "content": sys.argv[3]}]
call = ask(turn)
reply = ask([*turn, {"role": "assistant", "content": [call]}, {"role": "user", "content": [{"type": "tool_result", "tool_use_id": call["id"], "content": "     1\\u21923bde18dfd6b9-tool\\n"}]}])
print(json.dumps({"call": call, "reply": reply}))
server.shutdown()
`;
      const r = spawnSync("python3", ["-I", "-c", play, dirname(MODEL_STUB_PY), script, journeyReadPrompt("Name the planet.", file)], { encoding: "utf8" });
      expect(r.stderr).toBe("");
      const { call, reply } = JSON.parse(r.stdout);
      expect(call).toMatchObject({ type: "tool_use", name: "Read", input: { file_path: file } });
      expect(reply.text).toBe("Stub reply 3bde18dfd6b9. The tool printed 3bde18dfd6b9-tool.");
      // The person's own prompt, with no marker, still gets the default turn (its shell call) elsewhere.
      expect(JOURNEY_STUB_SCRIPT.steps[0]).toHaveProperty("shell");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
  test("Codex's reserved home chat turn is text only: Codex offers no Read, and its shell waits under policy ask", () => {
    // Prod run 46090508199: the Read came back "unsupported call: Read" and the reply said "The tool printed .".
    const turn = JOURNEY_STUB_SCRIPT.turns.find((t) => new RegExp(t.match).test(journeyTextPrompt("Name the planet.")));
    expect(turn?.steps).toEqual([{ text: journeyTextReply("{{nonce}}") }]);
    expect(new RegExp(turn!.match).test(journeyReadPrompt("Name the planet.", "/tmp/x"))).toBe(false);
    expect(journeyTextReply("3bde18dfd6b9")).toStartWith("Stub reply 3bde18dfd6b9. ");
  });
  test("a team machine gets the DEV creator allowance, as a nightly build copies", () => {
    const team = claudeLoginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"), true);
    expect(team.preflight).toContain("owner|team");
    expect(team.install("/p.json")).toContain("'/p.json' owner,team <<");
    expect(claudeLoginPrograms(readFileSync(INSTALLER_SWIFT, "utf8")).install("/p.json")).toContain("'/p.json' owner <<");
  });
  test("Codex: the made-up sign-in passes the app's validation and the installer gets the codex provider", () => {
    const auth = stubCodexAuth("ab".repeat(16), new Date("2026-11-04T00:00:00Z"));
    expect(validLogin("codex", auth)).toBe(true);
    expect(validLogin("codex", JSON.stringify({ OPENAI_API_KEY: "sk-x", tokens: {} }))).toBe(false);
    expect(validLogin("claude", auth)).toBe(false);
    expect(loginBearer("codex", auth)).toBe(JSON.parse(auth).tokens.access_token);
    expect(loginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"), "codex").install("/p.json")).toContain("python3 - 'codex' '/p.json' owner <<");
  });
  test("Codex: the stub config pins the stub's model and keeps the made-up sign-in off chatgpt.com", () => {
    const dir = mkdtempSync(join(tmpdir(), "journey-codex-config-"));
    // Runs CODEX_STUB_CONFIG on a config.toml, then reads it back with Python's own TOML parser.
    const point = (before: string | null) => {
      const file = join(dir, "config.toml");
      rmSync(file, { force: true });
      if (before !== null) writeFileSync(file, before);
      const run = (args: string[], input: string) => spawnSync("python3", args, { input, encoding: "utf8" });
      const r = run(["-", "4711", file], CODEX_STUB_CONFIG);
      expect(r.stderr).toBe("");
      expect(r.stdout.trim()).toBe("stub-ready");
      const read = run(["-c", "import json, sys, tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], 'rb'))))", file], "");
      expect(read.stderr).toBe("");
      return JSON.parse(read.stdout);
    };
    try {
      const want = (c: any) => {
        expect(c.model).toBe("stub-model");
        expect(c.model_provider).toBe("journeystub");
        expect(c.chatgpt_base_url).toBe("http://127.0.0.1:4711/backend-api/");
        expect(c.model_providers.journeystub).toEqual({ name: "journey stub", base_url: "http://127.0.0.1:4711/v1", wire_api: "responses", requires_openai_auth: true });
        expect(c.features).toMatchObject({ apps: false, plugins: false, remote_plugin: false });
        expect(c.analytics.enabled).toBe(false);
      };
      want(point(null));
      // The image's own settings stay; the keys the stub needs replace theirs, in the tables they already have.
      const image = 'model = "gpt-6.1-sol"\napproval_policy = "never"\n\n[features]\nplugins = true\nshell_snapshot = true\n\n[analytics]\nenabled = true\n\n[projects."/home/cmux"]\ntrust_level = "trusted"\n';
      const c = point(image);
      want(c);
      expect(c.approval_policy).toBe("never");
      expect(c.features.shell_snapshot).toBe(true);
      expect(c.projects["/home/cmux"].trust_level).toBe("trusted");
      // An active profile's model and model_provider would win over the root ones: no profile stays active.
      const profiled = point('profile = "work"\n\n[profiles.work]\nmodel = "gpt-6.1-sol"\nmodel_provider = "openai"\n');
      want(profiled);
      expect(profiled.profile).toBeUndefined();
      expect(profiled.profiles.work.model).toBe("gpt-6.1-sol");
      // A second run (a resumed machine) rewrites the provider table instead of adding one TOML refuses.
      want(point(readFileSync(join(dir, "config.toml"), "utf8")));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("cloud journey: Claude login route (cmux#40159)", () => {
  const base = { modelStub: false, provider: "claude", login: "sk-ant-oat01-x", gatewayAny: false, startVia: "acp" };
  test("a real-model Claude chat runs on the launch credential, as the app sends it, never a copied login", () => {
    // Production machines hold no login and have no model route of their own (acpmux cloud_model_plane where_resolves):
    // a copied login is a path no person's chat takes since cmux#40159, so the matrix's subscription row must not use it.
    expect(startsOnLaunchCredential(base)).toBe(true);
    expect(startsOnLaunchCredential({ ...base, modelStub: true })).toBe(true);
  });
  test("Codex, a gateway run, an app-driven start and a run with no login keep their own routes", () => {
    expect(startsOnLaunchCredential({ ...base, provider: "codex" })).toBe(false);
    expect(startsOnLaunchCredential({ ...base, gatewayAny: true })).toBe(false);
    expect(startsOnLaunchCredential({ ...base, startVia: "app" })).toBe(false);
    expect(startsOnLaunchCredential({ ...base, login: "" })).toBe(false);
    // A --preclaim-login run measures the spare.ready copy itself.
    expect(startsOnLaunchCredential({ ...base, preclaimLogin: true })).toBe(false);
    expect(startsOnLaunchCredential({ ...base, modelStub: true, preclaimLogin: true })).toBe(true);
  });

  test("a preclaim miss starts the agent on its launch credential, not a post-bind copy", () => {
    expect(loginPathAfterClaim({ receipt: true, launchCredential: false, launchOnMiss: true })).toBe("receipt");
    expect(loginPathAfterClaim({ receipt: false, launchCredential: false, launchOnMiss: true })).toBe("launch");
    expect(loginPathAfterClaim({ receipt: false, launchCredential: true, launchOnMiss: true })).toBe("launch");
    // Codex, --gateway or --start-via app: no launch credential path, so the copy stays.
    expect(loginPathAfterClaim({ receipt: false, launchCredential: false, launchOnMiss: false })).toBe("copy");
  });
});

describe("cloud journey: login preflight", () => {
  test("the login preflight waits for the guest's bind, then names the failing check", async () => {
    const noPause = async () => {};
    let calls = 0;
    const late = async (command: string) => ({ code: command === "pre" && ++calls >= 3 ? 0 : 1, stdout: "", stderr: "" });
    expect(await waitPreflight(late, "pre", "owner", 90_000, 0, noPause)).toMatchObject({ tries: 3 });
    const never = async (command: string) => ({ code: command === PREFLIGHT_PROBE ? 0 : 1, stdout: command === PREFLIGHT_PROBE ? "vm-kind= agent-auth.sh=yes user=cmux\n" : "", stderr: "" });
    await expect(waitPreflight(never, "pre", "owner", 0, 0, noPause)).rejects.toThrow(/preflight exit 1 after 1 tries .*not an owner machine with the image's launchers \(vm-kind= agent-auth.sh=yes user=cmux\)/);
  });

  test("a launch-credential start waits for the claimed spare's kind record to read owner (run 45276109812 shard 30-0)", async () => {
    const noPause = async () => {};
    const kinds = ["team", "team", "owner"];
    const seen: string[] = [];
    const late = async (command: string) => { seen.push(command); return { code: 0, stdout: `vm-kind=${kinds.shift() ?? "owner"}\n`, stderr: "" }; };
    expect(await waitOwnerKind(late, 90_000, 0, noPause)).toMatchObject({ tries: 3, first: "team" });
    expect(seen.every((c) => c === OWNER_KIND_PROGRAM)).toBe(true);
    // The program nudges the image's sync (root) before it reads the record again, and never needs a password.
    expect(OWNER_KIND_PROGRAM).toContain("sudo -n /usr/local/bin/cmux-vm-kind-sync");
    const never = async () => ({ code: 0, stdout: "vm-kind=team\n", stderr: "" });
    await expect(waitOwnerKind(never, 0, 0, noPause)).rejects.toThrow(/vm-kind reads team after 1 tries .*team mode \(CodeRouter\)/);
    const unread = async () => ({ code: 255, stdout: "", stderr: "" });
    await expect(waitOwnerKind(unread, 0, 0, noPause)).rejects.toThrow(/reads unread \(exit 255\)/);
  });

  test("the owner read rides the start's exec: one trip on an owner record, the old wait and a lone start otherwise", async () => {
    // Real leg 45563753386 / 45571173365: the owner read was its own exec, 1.6 to 2.3 s before the start's.
    const seen: string[] = [];
    let kindMs: number | null | undefined;
    const owner = async (command: string) => { seen.push(command); return { code: 0, stdout: "vm-kind=owner\n@@kind_ms 12\n@@session s\n@@prompted\n@@guest_ms 40\n", stderr: "" }; };
    let waited = 0;
    const r = await startAfterOwnerKind(owner, "START", 120_000, async () => { waited++; }, (ms) => { kindMs = ms; });
    expect(seen).toHaveLength(1);
    expect(seen[0].indexOf(OWNER_KIND_PROGRAM)).toBeGreaterThanOrEqual(0);
    expect(seen[0].indexOf(OWNER_KIND_PROGRAM)).toBeLessThan(seen[0].indexOf("START"));
    expect(waited).toBe(0);
    expect(kindMs).toBe(12);
    expect(r.stdout).toContain("@@prompted");
    // Not owner yet: the gate keeps the start from running, the journey's wait runs, then the start alone.
    const seen2: string[] = [];
    const team = async (command: string) => { seen2.push(command); return seen2.length === 1 ? { code: OWNER_KIND_GATE_EXIT, stdout: "vm-kind=team\n@@kind_ms 9\n", stderr: "" } : { code: 0, stdout: "@@session s\n", stderr: "" }; };
    await startAfterOwnerKind(team, "START", 120_000, async () => { waited++; }, () => { throw new Error("not owner"); });
    expect(waited).toBe(1);
    expect(seen2).toHaveLength(2);
    expect(seen2[1]).not.toContain(OWNER_KIND_PROGRAM);
    // A wait that fails fails the start as before, with no start run.
    const seen3: string[] = [];
    const none = async (command: string) => { seen3.push(command); return { code: OWNER_KIND_GATE_EXIT, stdout: "vm-kind=team\n", stderr: "" }; };
    await expect(startAfterOwnerKind(none, "START", 120_000, async () => { throw new Error("vm-kind reads team"); }, () => {})).rejects.toThrow(/vm-kind reads team/);
    expect(seen3).toHaveLength(1);
    // The gate itself, in a shell: a record that is not owner stops before the start.
    const dir = mkdtempSync(join(tmpdir(), "owner-gate-"));
    const program = (kind: string) => ownerKindGated(`echo STARTED`).replaceAll("/etc/cmux/vm-kind", join(dir, kind)).replaceAll("/usr/local/bin/cmux-vm-kind-sync", join(dir, "no-sync"));
    writeFileSync(join(dir, "owner"), "owner\n");
    writeFileSync(join(dir, "team"), "team\n");
    const ran = spawnSync("bash", ["-c", program("owner")], { encoding: "utf8" });
    expect(ran.status).toBe(0);
    expect(ran.stdout).toMatch(/vm-kind=owner\n@@kind_ms \d+\nSTARTED/);
    const gated = spawnSync("bash", ["-c", program("team")], { encoding: "utf8" });
    expect(gated.status).toBe(OWNER_KIND_GATE_EXIT);
    expect(gated.stdout).not.toContain("STARTED");
    rmSync(dir, { recursive: true });
  });
});

describe("cloud journey: app cli", () => {
  test("app cli: machines new since a create are listed, never picked", () => {
    expect(machineIds([{ id: "vm_a" }, { machine_id: "vm_b" }, { id: "vm_c", status: "deleted" }, {}])).toEqual(["vm_a", "vm_b"]);
    expect(newMachineIds(["vm_a"], ["vm_a", "vm_b", "vm_b"])).toEqual(["vm_b"]);
    expect(newMachineIds(["vm_a"], ["vm_a"])).toEqual([]);
  });
});

describe("cloud journey: leaked machine sweep", () => {
  const now = Date.UTC(2026, 10, 9, 12, 0, 0);
  const tagAt = (ms: number) => `jr-${ms.toString(36)}`;
  const ids = (rows: any[], at = now) => staleJourneyMachines(rows, at).map((m) => m.id);

  test("a failed drill machine is taken once its run is FAILED_JOURNEY_MS old, not after LONG_JOURNEY_MS (run 45979891007 left six)", () => {
    const t20 = tagAt(now - 20 * 60_000);
    const t5 = tagAt(now - 5 * 60_000);
    expect(FAILED_JOURNEY_MS).toBe(15 * 60_000);
    expect(ids([
      { id: "dead_long", name: `cloud journey auto ${t20} long`, status: "failed", last_active_at: now - 60_000 },
      { id: "dead_move", name: `cloud journey auto ${t20} long move B`, status: "failed" },
      { id: "young", name: `cloud journey auto ${t5} long`, status: "failed" },
      { id: "live", name: `cloud journey auto ${t20} long`, status: "running" },
      { id: "kept", name: `cloud journey ${t20}`, status: "failed" },
      { id: "theirs", name: `fp-${t20}`, status: "failed" },
    ])).toEqual(["dead_long", "dead_move"]);
  });

  test("machinesByState counts each state, most first", () => {
    expect(machinesByState([{ status: "paused" }, { status: "failed" }, { status: "paused" }, {}])).toBe("paused 2, failed 1, ? 1");
    expect(machinesByState([])).toBe("none");
  });

  test("takes only an auto-named journey machine (and gateway) older than any journey run, in any state", () => {
    const old = tagAt(now - STALE_JOURNEY_MS - 60_000);
    const young = tagAt(now - STALE_JOURNEY_MS + 60_000);
    expect(ids([
      { id: "vm_running", name: `cloud journey auto ${old}`, status: "running" },
      { id: "vm_paused_gw", name: `cloud journey auto ${old} gateway`, status: "paused" },
      { id: "vm_move_b", name: `cloud journey auto ${old} move B`, status: "running" },
      { id: "vm_cold", name: `cloud journey auto ${old} cold`, status: "paused" },
      { id: "vm_young", name: `cloud journey auto ${young}`, status: "paused" },
      { id: "vm_gone", name: `cloud journey auto ${old}`, status: "deleted" },
      { id: "vm_deleting", name: `cloud journey auto ${old}`, status: "deleting" },
    ])).toEqual(["vm_running", "vm_paused_gw", "vm_move_b", "vm_cold"]);
    // Just inside the bound is a concurrent run's machine; just past it is leaked.
    const edge = { id: "vm_edge", name: `cloud journey auto ${tagAt(now - STALE_JOURNEY_MS)}`, status: "paused" };
    expect(ids([edge])).toEqual([]);
    expect(ids([edge], now + 1)).toEqual(["vm_edge"]);
  });

  test("never a machine with recent activity, however old", () => {
    const old = tagAt(now - 2 * STALE_JOURNEY_MS);
    expect(ids([
      { id: "vm_active", name: `cloud journey auto ${old}`, status: "running", last_active_at: now - 5 * 60_000 },
      { id: "vm_edge", name: `cloud journey auto ${old}`, status: "running", last_active_at: now - IDLE_JOURNEY_MS },
      { id: "vm_idle", name: `cloud journey auto ${old}`, status: "running", last_active_at: now - IDLE_JOURNEY_MS - 1 },
    ])).toEqual(["vm_idle"]);
  });

  test("the age bound outlasts every workflow job that runs a journey, twice over", () => {
    const dir = join(import.meta.dir, "../../.github/workflows");
    const seen: string[] = [];
    const long: string[] = [];
    for (const f of readdirSync(dir).filter((n) => /\.ya?ml$/.test(n))) {
      const text = readFileSync(join(dir, f), "utf8");
      if (!/cloud-journey(\.ts|-ci\.sh)/.test(text)) continue;
      seen.push(f);
      // A file that runs a long journey (its machines named `… long`) is held to the long bound; every other to 3 h.
      const isLong = /--resume-matrix|--wake-echo/.test(text);
      if (isLong) long.push(f);
      const bound = isLong ? LONG_JOURNEY_MS : STALE_JOURNEY_MS;
      // Every timeout in a job that runs a journey (its block names the script); a file that names it but no job
      // that does (a matrix that runs it through another script) holds every job. A job that runs none, like
      // backend.yml's `test` (95 min, #56565), makes no journey machine and so needs no age bound.
      const jobs = (text.split(/^jobs:\s*$/m)[1] ?? text).split(/^(?=  [A-Za-z0-9_-]+:\s*$)/m);
      const journeyJobs = jobs.filter((j) => /cloud-journey(\.ts|-ci\.sh)/.test(j));
      for (const job of journeyJobs.length ? journeyJobs : jobs) {
        const name = /^  ([A-Za-z0-9_-]+):/.exec(job)?.[1] ?? "?";
        for (const m of job.matchAll(/timeout-minutes:\s*(\d+)/g)) {
          expect({ f, name, fits: Number(m[1]) * 60_000 * 2 <= bound }).toEqual({ f, name, fits: true });
        }
      }
    }
    expect(seen).toContain("cmux-vm.yml");
    expect(long).toContain("cloud-resume-matrix.yml");
  });

  test("a CI run's machines carry a ttl past any run that named them; a hand run's none unless asked", () => {
    const ci = { GITHUB_ACTIONS: "true" };
    expect(journey.journeyMachineTtl(false, ci)).toEqual({ ttl_seconds: STALE_JOURNEY_MS / 2 / 1000 });
    expect(journey.journeyMachineTtl(true, ci)).toEqual({ ttl_seconds: LONG_JOURNEY_MS / 1000 });
    expect(journey.journeyMachineTtl(false, {})).toEqual({});
    expect(journey.journeyMachineTtl(false, { CLOUD_JOURNEY_MACHINE_TTL_S: "3600" })).toEqual({ ttl_seconds: 3600 });
    expect(journey.journeyMachineTtl(false, { ...ci, CLOUD_JOURNEY_MACHINE_TTL_S: "0" })).toEqual({});
    expect(() => journey.journeyMachineTtl(false, { CLOUD_JOURNEY_MACHINE_TTL_S: "60" })).toThrow(/300 to 604800/);
  });

  test("a long run's machines (` long`) get the long bound; a short run's leak is swept after 3 h", () => {
    const fiveHours = tagAt(now - 5 * 3_600_000);
    const pastLong = tagAt(now - LONG_JOURNEY_MS - 60_000);
    expect(autoMachineName(fiveHours, false)).toBe(`cloud journey auto ${fiveHours}`);
    expect(autoMachineName(fiveHours, true)).toBe(`cloud journey auto ${fiveHours} long`);
    expect(ids([
      // 2026-11-25's staging leftovers: 5 h old short runs, which the 11 h bound for every machine kept.
      { id: "vm_short", name: autoMachineName(fiveHours, false), status: "paused" },
      { id: "vm_short_cold", name: `${autoMachineName(fiveHours, false)} cold`, status: "paused" },
      { id: "vm_long", name: autoMachineName(fiveHours, true), status: "paused" },
      { id: "vm_long_gw", name: `${autoMachineName(fiveHours, true)} gateway`, status: "paused" },
      { id: "vm_long_old", name: autoMachineName(pastLong, true), status: "paused" },
      { id: "vm_glued", name: `cloud journey auto ${fiveHours} longer`, status: "paused" },
    ])).toEqual(["vm_short", "vm_short_cold", "vm_long_old", "vm_glued"]);
  });

  test("never a --keep run's plain name, another name or a tag that is not a time", () => {
    const old = tagAt(now - 48 * 3600_000);
    expect(ids([
      { id: "vm_kept", name: `cloud journey ${old}`, status: "paused" },
      { id: "vm_kept_gw", name: `cloud journey ${old} gateway`, status: "failed" },
      { id: "vm_dev", name: "dev machine", status: "paused" },
      { id: "vm_named", name: `my cloud journey auto ${old}`, status: "paused" },
      { id: "vm_bad", name: "cloud journey auto jr-!!", status: "paused" },
      { id: "vm_tiny", name: "cloud journey auto jr-zz", status: "paused" },
      { id: "vm_tiny_sfx", name: "cloud journey auto jr-zz move B", status: "paused" },
      { id: "vm_glued", name: `cloud journey auto ${old}x`, status: "paused" },
      { id: "vm_future", name: `cloud journey auto ${tagAt(now + 3600_000)}`, status: "paused" },
      null,
    ])).toEqual([]);
    const [m] = staleJourneyMachines([{ id: "vm_x", name: `cloud journey auto ${old}`, status: "paused", created_at: now - 48 * 3600_000 }], now);
    expect(m).toEqual({ id: "vm_x", name: `cloud journey auto ${old}`, status: "paused", created: new Date(now - 48 * 3600_000).toISOString() });
  });

  test("takes the Auto mode journey's leftovers (auto journey aj-<tag>), by the same age and name rules", () => {
    const now = Date.UTC(2026, 10, 25, 9, 0, 0);
    const aj = (ms: number) => `aj-${ms.toString(36)}`;
    const ids = staleJourneyMachines([
      { id: "vm_aj_old", name: `auto journey ${aj(now - STALE_JOURNEY_MS - 60_000)}`, status: "running" },
      { id: "vm_aj_young", name: `auto journey ${aj(now - STALE_JOURNEY_MS + 60_000)}`, status: "running" },
      { id: "vm_aj_suffix", name: `auto journey ${aj(now - STALE_JOURNEY_MS - 60_000)} kept`, status: "paused" },
      { id: "vm_aj_person", name: "my auto journey", status: "paused" },
    ], now).map((m) => m.id);
    expect(ids).toEqual(["vm_aj_old"]);
  });

  test("reads every page of the machine list", async () => {
    const pages: Record<string, any> = {
      "": { machines: [{ id: "a" }], next_cursor: "c1" },
      c1: { machines: [{ id: "b" }], next_cursor: "c2" },
      c2: { machines: [{ id: "c" }], next_cursor: null },
    };
    const asked: any[] = [];
    const rows = await listAllMachines(async (p) => { asked.push(p); return pages[String(p.cursor ?? "")]; });
    expect(rows.map((r) => r.id)).toEqual(["a", "b", "c"]);
    expect(asked).toEqual([{ limit: 100 }, { limit: 100, cursor: "c1" }, { limit: 100, cursor: "c2" }]);
    // A list that never ends is an error (the sweep then deletes nothing), not a partial sweep.
    await expect(listAllMachines(async () => ({ machines: [], next_cursor: "again" }), 3)).rejects.toThrow("more than 3 pages");
  });
});

describe("cloud journey: leaked install sweep", () => {
  const now = Date.UTC(2026, 10, 16, 9, 0, 0);
  const tagAt = (ms: number) => `jr-${ms.toString(36)}`;
  // Installs keep the long bound: a long run still uses its install.
  const old = tagAt(now - LONG_JOURNEY_MS - 60_000);
  const young = tagAt(now - LONG_JOURNEY_MS + 60_000);
  const inst = (id: string, name: string, extra: Record<string, unknown> = {}) => ({ id, name, kind: "cli", revoked_at: null, ...extra });

  test("takes only a live cli install a journey run named, older than any journey run", () => {
    expect(staleJourneyInstalls([
      inst("i_old", `cloud journey ${old}`),
      inst("i_young", `cloud journey ${young}`),
      inst("i_revoked", `cloud journey ${old}`, { revoked_at: now - 1000 }),
      inst("i_mac", `cloud journey ${old}`, { kind: "mac" }),
      inst("i_person", "Leo's MacBook"),
      inst("i_auto", `cloud journey auto ${old}`),
      inst("i_future", `cloud journey ${tagAt(now + 3_600_000)}`),
      inst("i_nottime", "cloud journey jr-zz"),
    ], now)).toEqual(["i_old"]);
  });

  test("takes the Auto mode journey's live cli install (auto journey aj-<tag>) once it is older than any run", () => {
    const aj = (ms: number) => `aj-${ms.toString(36)}`;
    expect(staleJourneyInstalls([
      inst("i_aj_old", `auto journey ${aj(now - LONG_JOURNEY_MS - 60_000)}`),
      inst("i_aj_young", `auto journey ${aj(now - LONG_JOURNEY_MS + 60_000)}`),
      inst("i_aj_revoked", `auto journey ${aj(now - LONG_JOURNEY_MS - 60_000)}`, { revoked_at: now - 1000 }),
      inst("i_aj_jr", `auto journey ${old}`),
    ], now)).toEqual(["i_aj_old"]);
  });

  test("a malformed list row is skipped, never thrown on", () => {
    expect(staleJourneyInstalls([null, {}, { name: 7 }, inst("", `cloud journey ${old}`)], now)).toEqual([]);
  });
});

describe("carrier dial step", () => {
  // A stand-in for `cmux carrier dial`: its status and route lines on stderr, then the daemon's answer to each line.
  const fakeCmux = (body: string) => {
    const dir = mkdtempSync(join(tmpdir(), "journey-carrier-"));
    const bin = join(dir, "cmux");
    writeFileSync(bin, `#!/bin/bash\nprintf '%s\\n' "$*" > "${dir}/args"\nprintf '%s\\n' "$CMUX_CLOUD_API_URL $CMUX_CLOUD_ACCESS_TOKEN \${CMUX_CLOUD_TEAM:--}" > "${dir}/env"\n${body}\n`, { mode: 0o755 });
    return { dir, bin };
  };
  const api = { origin: "https://api.example", bearer: "session-value", team: "team_0123456789abcdef0123" };

  test("passes on the carrier route and the daemon's answer, with the dial's own connect time", async () => {
    const { dir, bin } = fakeCmux(`echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=ok ms=812' >&2
read -r line; echo '{"event":"pushed","conn":0}'; echo '{"id":1,"ok":true,"data":{"app":"cmux-tui","protocol":12}}'; cat >/dev/null`);
    process.env.CMUX_CLOUD_TEAM = "team_inherited000000000000";
    const d = await carrierDial(bin, { ...api, team: undefined }, "vm_abcdefghij0123456789", 2_000).finally(() => delete process.env.CMUX_CLOUD_TEAM);
    expect(d.connectMs).toBe(812);
    expect(d.reply).toBe('{"id":1,"ok":true,"data":{"app":"cmux-tui","protocol":12}}');
    expect(d.replyMs).toBeGreaterThanOrEqual(0);
    // No team of its own: none is passed, and the inherited CMUX_CLOUD_TEAM is dropped.
    expect(readFileSync(join(dir, "args"), "utf8").trim()).toBe("carrier dial --machine vm_abcdefghij0123456789 --deadline-ms 2000");
    expect(readFileSync(join(dir, "env"), "utf8").trim()).toBe("https://api.example session-value -");
    rmSync(dir, { recursive: true, force: true });
  });

  test("a failed attempt the dial retries is counted, and the ok attempt's time is the connect time", async () => {
    const { dir, bin } = fakeCmux(`echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=relay ms=3001' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=ok ms=640' >&2
read -r line; echo '{"id":1,"ok":true,"data":{"app":"cmux-tui"}}'; cat >/dev/null`);
    const d = await carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000);
    expect({ connectMs: d.connectMs, retries: d.retries, failed: d.failed }).toEqual({ connectMs: 640, retries: 1, failed: ["relay 3001 ms"] });
    rmSync(dir, { recursive: true, force: true });
  });

  test("a dial that gives up names every failed attempt, from the route lines after its status line", async () => {
    const { dir, bin } = fakeCmux(`echo '{"ok":false,"error_code":"relay"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=relay ms=15003' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=reconnect outcome=handshake ms=902' >&2
exit 1`);
    await expect(carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("(failed attempts: relay 15003 ms, handshake 902 ms)");
    rmSync(dir, { recursive: true, force: true });
  });

  test("a dial cut off before an ok attempt names the failed ones", async () => {
    const { dir, bin } = fakeCmux(`echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=relay ms=3001' >&2
exit 1`);
    await expect(carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("ended with no ok route line (failed attempts: relay 3001 ms)");
    rmSync(dir, { recursive: true, force: true });
  });

  test("each attempt's phases come from the dial's own connect log, and the state dir goes with the dial", async () => {
    const { dir, bin } = fakeCmux(`mkdir -p "$CMUX_TUI_STATE_DIR/carrier"; echo "$CMUX_TUI_STATE_DIR" > "${"$"}{0%/*}/state"
log="$CMUX_TUI_STATE_DIR/carrier/connect.log"
echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=relay ms=3001' >&2
echo 'carrier.phases machine=vm_x phase=connect carrier=relay:0 outcome=relay ticket_ms=410 relay_ms=2591 parked_ms=0 handshake_ms=0 mux_ms=0 lanes=0 ms=3001' >> "$log"
echo 'cloud.connect route=carrier machine=vm_x phase=reconnect outcome=ok ms=640' >&2
echo 'carrier.phases machine=vm_x phase=reconnect carrier=relay:0 outcome=ok ticket_ms=300 relay_ms=40 parked_ms=120 handshake_ms=150 mux_ms=30 lanes=3 ms=640' >> "$log"
read -r line; echo '{"id":1,"ok":true,"data":{"app":"cmux-tui"}}'; cat >/dev/null`);
    const d = await carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000);
    expect(d.phases).toEqual(["connect relay: ticket 410, relay 2591, parked 0, handshake 0, mux 0 ms, lanes 0, 3001 ms",
      "reconnect ok: ticket 300, relay 40, parked 120, handshake 150, mux 30 ms, lanes 3, 640 ms"]);
    expect(dialDetail(d)).toContain("1 retried attempts (relay 3001 ms); phases: connect relay: ticket 410");
    expect(dialDetail(d)).not.toContain("vm_x");
    expect(existsSync(readFileSync(join(dir, "state"), "utf8").trim())).toBe(false);
    rmSync(dir, { recursive: true, force: true });
  });

  test("a dial that gives up shows each attempt's phases too", async () => {
    const { dir, bin } = fakeCmux(`mkdir -p "$CMUX_TUI_STATE_DIR/carrier"
echo 'carrier.phases machine=vm_x phase=connect carrier=relay:0 outcome=parked_timeout ticket_ms=200 relay_ms=30 parked_ms=1700 handshake_ms=0 mux_ms=0 lanes=1 ms=1930' >> "$CMUX_TUI_STATE_DIR/carrier/connect.log"
echo '{"ok":false,"error_code":"parked_timeout"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=parked_timeout ms=1930' >&2
exit 1`);
    await expect(carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow(
      "(failed attempts: parked_timeout 1930 ms) (phases: connect parked_timeout: ticket 200, relay 30, parked 1700, handshake 0, mux 0 ms, lanes 1, 1930 ms)");
    rmSync(dir, { recursive: true, force: true });
  });

  test("a refused identify shows the attempts' phases too", async () => {
    const { dir, bin } = fakeCmux(`mkdir -p "$CMUX_TUI_STATE_DIR/carrier"
echo 'carrier.phases machine=vm_x phase=connect carrier=relay:0 outcome=ok ticket_ms=200 relay_ms=30 parked_ms=90 handshake_ms=110 mux_ms=20 lanes=3 ms=450' >> "$CMUX_TUI_STATE_DIR/carrier/connect.log"
echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=ok ms=450' >&2
read -r line; echo '{"id":1,"ok":false,"error":"denied"}'; cat >/dev/null`);
    await expect(carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow(
      /identify answered .* \(phases: connect ok: ticket 200, relay 30, parked 90, handshake 110, mux 20 ms, lanes 3, 450 ms\)/);
    rmSync(dir, { recursive: true, force: true });
  });

  test("dialPhases keeps a field it does not know, and nothing but phases lines", () => {
    expect(dialPhases("noise\ncarrier.phases machine=vm_x phase=connect outcome=relay ticket_ms=1 ms=2 detail=4003\n")).toEqual(
      ["connect relay: ticket 1 ms, detail 4003, 2 ms"]);
  });

  test("a route line before the status line is out of contract", async () => {
    const { dir, bin } = fakeCmux(`echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=ok ms=5' >&2
echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
read -r line; echo '{"id":1,"ok":true,"data":{"app":"cmux-tui"}}'; cat >/dev/null`);
    await expect(carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("a route line before the status line");
    rmSync(dir, { recursive: true, force: true });
  });

  test("names the step the dial did not get past", async () => {
    const { dir, bin } = fakeCmux(`echo '{"ok":false,"error_code":"parked_timeout"}' >&2; exit 1`);
    await expect(carrierDial(bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("parked_timeout");
    rmSync(dir, { recursive: true, force: true });
  });

  test("refuses another route, and a stream that ends with no answer", async () => {
    const other = fakeCmux(`echo '{"ok":true,"path_state":"relay","route":"link"}' >&2; cat >/dev/null`);
    await expect(carrierDial(other.bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("route link, not carrier");
    const silent = fakeCmux(`echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=ok ms=5' >&2
exit 0`);
    await expect(carrierDial(silent.bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("before the daemon answered");
    for (const d of [other.dir, silent.dir]) rmSync(d, { recursive: true, force: true });
  });

  test("an identify refused or answered with no identity fails, and a dial that exits before the write fails the step", async () => {
    const connected = `echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
echo 'cloud.connect route=carrier machine=vm_x phase=connect outcome=ok ms=5' >&2`;
    const refused = fakeCmux(`${connected}\nread -r line; echo '{"id":1,"ok":false,"error":"denied"}'; cat >/dev/null`);
    await expect(carrierDial(refused.bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("identify answered");
    const bare = fakeCmux(`${connected}\nread -r line; echo '{"id":1,"ok":true,"data":{}}'; cat >/dev/null`);
    await expect(carrierDial(bare.bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("identify answered");
    const gone = fakeCmux(`${connected}\nexec 0<&-; exit 0`);
    await expect(carrierDial(gone.bin, api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("carrier dial");
    await expect(carrierDial("/nonexistent/cmux", api, "vm_abcdefghij0123456789", 2_000)).rejects.toThrow("carrier dial: ");
    for (const d of [refused.dir, bare.dir, gone.dir]) rmSync(d, { recursive: true, force: true });
  });

  test("the gateway hop cost drops the warm-up, needs every call answered 200, and reports ms percentiles", () => {
    const lines = (rows: string[]) => ["noise", ...rows.map((r) => `hop-t ${r}`)].join("\n");
    const out = lines(["200 9.000 9.000 0", ...Array.from({ length: 10 }, (_, i) => `200 ${((i + 1) / 100).toFixed(3)} ${((i + 1) / 10).toFixed(3)} 0`)]);
    expect(hopTimes(out, 10)).toEqual({ ttfb_p50: 50, ttfb_p90: 90, total_p50: 500, total_p90: 900 });
    expect(() => hopTimes(lines(["200 0.1 0.1 0", "200 0.1 0.1 0"]), 2)).toThrow("1 of 2 timed calls");
    expect(() => hopTimes(lines(["200 0.1 0.1 0", "502 0.1 0.1 0"]), 1)).toThrow("did not answer 200 whole (502 exit 0)");
    expect(() => hopTimes(lines(["200 0.1 0.1 0", "200 0.1 0.1 18"]), 1)).toThrow("(200 exit 18)");
  });

  test("the hop split reads each call's Server-Timing after its timing line and derives the object's own hop", () => {
    const call = (ttfb: number, st: string | null) => [`hop-t 200 ${(ttfb / 1000).toFixed(3)} 0.300 0`, ...(st ? [`hop-s ${st}`] : [])];
    const st = (auth: number, wd: number, wait: number, gw: number) => `auth;dur=${auth}, worker-do;dur=${wd}, do-wait;dur=${wait}, do-gateway;dur=${gw}`;
    const out = [
      ...call(900, st(90, 900, 90, 90)), // warm-up, dropped
      ...call(230, st(5, 200, 2, 150)),
      ...call(240, st(7, 210, 4, 160)),
      ...call(250, st(9, 220, 6, 170)),
    ].join("\n");
    expect(hopSpans(out)).toEqual({ calls: 3, untimed: 0, auth: 7, "worker-do": 210, "do-wait": 4, "do-gateway": 160, object_hop: 46, edge: 23 });
    // A counted call without the spans is reported, not hidden in a smaller sample.
    expect(hopSpans([out, ...call(260, null), ...call(270, "auth;dur=1")].join("\n"))).toMatchObject({ calls: 3, untimed: 2 });
    expect(hopSpans([...call(200, null), ...call(200, null)].join("\n"))).toBeNull();
    expect(hopSpans([...call(200, null), ...call(200, "auth;dur=1, worker-do;dur=2")].join("\n"))).toBeNull();
  });
});

describe("opRetryable", () => {
  test("retries only a cut-off provider call the API marks retryable", () => {
    expect(opRetryable({ ok: false, error: { code: "mutation.indeterminate", message: "the provider call was cut off; retry with the same key", retryable: true } })).toBe(true);
    expect(opRetryable({ ok: false, error: { code: "mutation.indeterminate", retryable: false } })).toBe(false);
    expect(opRetryable({ ok: false, error: { code: "cloud.provider.unavailable", retryable: true } })).toBe(false);
    expect(opRetryable({ ok: true, value: {} })).toBe(false);
    expect(opRetryable("vm_unavailable")).toBe(false);
  });
});

describe("deleteRetryable", () => {
  test("a delete retries an owner reset as well as a cut-off provider call (drill run 45979891007 leaked six)", () => {
    expect(deleteRetryable({ ok: false, error: { code: "owner.unreachable", message: "Error: Durable Object storage operation exceeded timeout which caused object to be reset.", retryable: true } })).toBe(true);
    expect(deleteRetryable({ ok: false, error: { code: "mutation.indeterminate", retryable: true } })).toBe(true);
    expect(deleteRetryable({ ok: false, error: { code: "owner.unreachable", retryable: false } })).toBe(false);
    expect(deleteRetryable({ ok: false, error: { code: "cloud.machine.not_found", retryable: false } })).toBe(false);
    expect(deleteRetryable({ ok: true, value: {} })).toBe(false);
  });
});

describe("Api owner.unreachable retry (cmux-platform#1442)", () => {
  const unreachable = { status: 503, body: { _tag: "OwnerUnreachable", code: "owner.unreachable", message: "Error: Network connection lost.", retryable: true } };
  const timedOut = { status: 503, body: { ok: false, error: { code: "owner.unreachable", message: "CallTimedOut: team machines: get did not answer", retryable: true } } };
  const ok = { status: 200, body: { ok: true, value: { id: "vm_1" } } };
  /** Answers each request with the next of `answers` (the last repeats) and keeps the bodies sent. */
  async function withAnswers<T>(answers: { status: number; body: unknown }[], run: (sent: any[]) => Promise<T>): Promise<T> {
    const sent: any[] = [];
    const real = globalThis.fetch;
    globalThis.fetch = (async (_url: string, init: RequestInit = {}) => {
      sent.push(JSON.parse(String(init.body)));
      const a = answers[Math.min(sent.length - 1, answers.length - 1)]!;
      return new Response(JSON.stringify(a.body), { status: a.status });
    }) as typeof fetch;
    try {
      return await run(sent);
    } finally {
      globalThis.fetch = real;
    }
  }
  const journey = () => new Journey(resolveBackend("staging"), null, {});
  const api = () => Object.assign(new Api("https://api.invalid"), { bearer: "t" });

  test("op() sends the same request once more under the same key, and the step says so", async () => {
    await withAnswers([unreachable, ok], async (sent) => {
      const J = journey();
      const v = await J.step("create", async () => ({ value: await api().op("cloud.machine.create", { name: "n" }, "tag-create"), detail: "vm_1" }));
      expect(v).toEqual({ id: "vm_1" });
      expect(sent.length).toBe(2);
      expect(sent[1]).toEqual(sent[0]);
      expect(sent[1].idempotency_key).toBe("tag-create");
      expect(J.steps[0]!.detail).toBe("vm_1; retried once after owner.unreachable");
    });
  });

  test("read() reads once more, and a second owner.unreachable fails the step naming the retry", async () => {
    await withAnswers([timedOut, ok], async (sent) => {
      expect(await api().read("cloud.machine.get", { machine: "vm_1" })).toEqual({ id: "vm_1" });
      expect(sent.length).toBe(2);
    });
    await withAnswers([unreachable], async (sent) => {
      const J = journey();
      await expect(J.step("get", async () => ({ value: await api().read("cloud.machine.get", { machine: "vm_1" }), detail: "" }))).rejects.toThrow("owner.unreachable");
      expect(sent.length).toBe(2);
      expect(J.steps[0]!.status).toBe("fail");
      expect(J.steps[0]!.detail).toContain("retried once after owner.unreachable");
    });
    await withAnswers([unreachable], async (sent) => {
      await expect(api().op("cloud.machine.start", { machine: "vm_1" }, "tag-start")).rejects.toThrow("owner.unreachable");
      expect(sent.length).toBe(2);
    });
  });

  test("op() asks a keyed op again under its key after the client timeout, and an unkeyed op not at all", async () => {
    const real = globalThis.fetch;
    const sent: any[] = [];
    // The first request never answers in time (what AbortSignal.timeout throws); the next answers.
    globalThis.fetch = (async (_url: string, init: RequestInit = {}) => {
      sent.push(JSON.parse(String(init.body)));
      if (sent.length === 1) throw new DOMException("The operation timed out.", "TimeoutError");
      return new Response(JSON.stringify(ok.body), { status: 200 });
    }) as typeof fetch;
    try {
      expect(await api().op("cloud.machine.create", { name: "n" }, "tag-parent-1")).toEqual({ id: "vm_1" });
      expect(sent.length).toBe(2);
      expect(sent[1]).toEqual(sent[0]);
      sent.length = 0;
      await expect(api().op("cloud.machine.create", { name: "n" })).rejects.toThrow("timed out");
      expect(sent.length).toBe(1);
    } finally {
      globalThis.fetch = real;
    }
  });

  test("no retry on other codes, on owner.unreachable not marked retryable, or on an op without a key", async () => {
    const answers = [
      { status: 503, body: { ok: false, error: { code: "cloud.provider.unavailable", retryable: true } } },
      { status: 503, body: { code: "owner.unreachable", retryable: false } },
      { status: 409, body: { ok: false, error: { code: "cloud.machine.busy", retryable: false } } },
    ];
    for (const a of answers) {
      // Every request gets the error: op and read each send exactly one.
      await withAnswers([a], async (sent) => {
        await expect(api().op("cloud.machine.start", { machine: "vm_1" }, "k")).rejects.toThrow();
        await expect(api().read("cloud.machine.get", { machine: "vm_1" })).rejects.toThrow();
        expect(sent.length).toBe(2);
      });
    }
    await withAnswers([unreachable, ok], async (sent) => {
      await expect(api().op("cloud.machine.start", { machine: "vm_1" })).rejects.toThrow("owner.unreachable");
      expect(sent.length).toBe(1);
    });
  });
});

describe("guest carrier timeline", () => {
  test("each guest time is ms after create's answer on the guest's boot clock, whatever its wall clock reads", () => {
    // The guest's wall clock runs 1000 ms ahead: guest_now 21_500 at uptime 10_500, the exec's midpoint 20_500, so
    // the guest booted at 10_000 here, the moment create answered.
    const out = ["guest_now 21500 10500", "clock 11200 11000", "wall bound.json 12500", "mono session_host_start 6000",
      "journal 5900 cmux-host[7]: cmux-host: session host 40 exited after 900 ms", "noise line"].join("\n");
    expect(guestTimeline(out, 10_000, 20_000, 21_000)).toBe(
      'after create\'s answer (±500 ms): guest boot +0 ms; bound.json +1500 ms; session_host_start +6000 ms; '
      + 'journal "cmux-host[7]: cmux-host: session host 40 exited after 900 ms" +5900 ms');
  });

  test("a file written before the guest's wall clock stepped is read in the clock it was written in", () => {
    // Booted with its wall clock 96 s behind (resumed from a snapshot), synced at 30 s after boot. bound.json was
    // written 4319 ms after boot under the old clock, carrier.json 40 s after boot under the new one.
    const out = ["guest_now 200100 100100", "clock 4500 4000", "clock 130000 100000", "wall bound.json 8319",
      "wall carrier.json 140000"].join("\n");
    expect(guestTimeline(out, 100_000, 200_000, 200_200)).toBe(
      "after create's answer (±100 ms; the guest's wall clock stepped +96000 ms after boot): guest boot +0 ms; "
      + "bound.json +4319 ms; carrier.json +40000 ms");
  });

  test("a machine bound before create answered reads as a claimed spare", () => {
    // Booted 8.8 days ago from its snapshot base and bound 231.5 s before create answered.
    const out = ["guest_now 1000000000 760954248", "wall bound.json 999768500"].join("\n");
    expect(guestTimeline(out, 1_000_000_000, 999_999_900, 1_000_000_100)).toBe(
      "after create's answer (±100 ms; a claimed spare: bound 231500 ms before create answered): guest boot -760954248 ms; bound.json -231500 ms");
  });

  test("a cold machine that binds while create's answer is on its way back is not a spare", () => {
    // Create was sent at 997_000 and answered at 1_000_000; the guest bound at 999_000, between the two.
    const out = ["guest_now 1000000000 60000", "wall bound.json 999999000"].join("\n");
    expect(guestTimeline(out, 1_000_000_000, 999_999_900, 1_000_000_100, 999_997_000)).toBe(
      "after create's answer (±100 ms): guest boot -60000 ms; bound.json -1000 ms");
  });

  test("says so when the guest showed nothing", () => {
    expect(guestTimeline("", 10_000, 20_000, 20_100)).toBe("after create's answer (±50 ms): no guest clock read");
  });

  test("the journal field reader reads a message past its escaped quotes", () => {
    const line = '{"__MONOTONIC_TIMESTAMP":"5900000","MESSAGE":"carrier \\"relay:0\\" registered","X":"y"}';
    const r = spawnSync("awk", [`${JOURNAL_FIELD} { print field("MESSAGE") "|" field("__MONOTONIC_TIMESTAMP") "|" field("missing") }`], { input: `${line}\n`, encoding: "utf8" });
    expect(r.stdout).toBe('carrier "relay:0" registered|5900000|\n');
  });
});


describe("cloud journey: carrier ticket without a cmux binary", () => {
  const key = Buffer.alloc(32, 7).toString("base64url");
  const whole = { relay: "relay+do://cmux-remote-relay-production.debussy.workers.dev", slot: "s_1-x", ticket: "t.t", grant: "g.g.g", daemon_key: key, expires_at: 2_000 };
  const answer = (patch: Record<string, unknown>) => ({ ok: true, value: { ...whole, ...patch } });
  test("an answer the dial takes passes", () => {
    expect(carrierTicketProblem(200, answer({}), 1_000)).toBeNull();
  });
  test("a refusal names its status", () => {
    expect(carrierTicketProblem(503, { ok: false, error: { code: "owner.unreachable" } }, 1_000)).toContain("HTTP 503");
  });
  test("the dial's relay rule: a bare relay+do:// with a host", () => {
    for (const relay of ["relay+do://", "wss://x", "relay+do://h/path", "relay+do://h?q=1", "relay+do://u@h", undefined])
      expect(carrierTicketProblem(200, answer({ relay }), 1_000)).toMatch(/relay/);
    expect(carrierTicketProblem(200, answer({ relay: "relay+do://h/" }), 1_000)).toBeNull();
  });
  test("the dial's slot, ticket and grant rules", () => {
    for (const slot of ["", " ", "a b", "x".repeat(129), 3]) expect(carrierTicketProblem(200, answer({ slot }), 1_000)).toContain("slot");
    for (const ticket of ["", "a b", undefined]) expect(carrierTicketProblem(200, answer({ ticket }), 1_000)).toContain("ticket");
    for (const grant of ["", " ", undefined]) expect(carrierTicketProblem(200, answer({ grant }), 1_000)).toContain("grant");
    expect(carrierTicketProblem(200, answer({}), 3_000)).toContain("not live");
  });
  test("the daemon key the dial pins is canonical 32-byte base64url", () => {
    expect(canonicalKey(key)).toBe(true);
    const lastChar = key.at(-1)!;
    const noncanonical = key.slice(0, -1) + (lastChar === "c" ? "d" : "c"); // same 32 bytes, other trailing bits
    expect(Buffer.from(noncanonical, "base64url").length).toBe(32);
    for (const daemon_key of [undefined, "k", `${key}=`, noncanonical, key.replace(/.$/, "+")])
      expect(carrierTicketProblem(200, answer({ daemon_key }), 1_000)).toContain("daemon_key");
  });
});

describe("cloud journey: desktop link readback (--desktop-link)", () => {
  // A stand-in for `cmux carrier dial --service desktop`: the status line, the host's `started` frame, then its link
  // notes in the connect log; what the viewer sent goes to a file.
  const fakeDesktop = (body: string) => {
    const dir = mkdtempSync(join(tmpdir(), "journey-desktop-"));
    const bin = join(dir, "cmux");
    writeFileSync(bin, `#!/bin/bash\nprintf '%s\\n' "$*" > "${dir}/args"\nmkdir -p "$CMUX_TUI_STATE_DIR/carrier"; log="$CMUX_TUI_STATE_DIR/carrier/connect.log"\n${body}\n`, { mode: 0o755 });
    return { dir, bin };
  };
  const api = { origin: "https://api.example", bearer: "session-value", team: undefined };
  const started = `printf '\\001\\033\\000\\000\\000{"t":"started","session":1}'`;

  test("reads the link's notes from the dial's own connect log, as the viewer that keeps the session", async () => {
    const { dir, bin } = fakeDesktop(`echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
cat > "${"$"}{0%/*}/stdin" <&0 &
sleep 0.3; ${started}
printf 'cloud.desktop_link machine=vm_x answered\\ncloud.desktop_link machine=vm_x up\\ncloud.desktop_link machine=vm_x host_up\\n' >> "$log"
wait`);
    const r = await desktopLinkDial(bin, api, "vm_abcdefghij0123456789", 10_000, 2_000);
    expect(r.error).toBeNull();
    expect(r.lines).toEqual(["cloud.desktop_link machine=vm_x answered", "cloud.desktop_link machine=vm_x up", "cloud.desktop_link machine=vm_x host_up"]);
    expect(r.controls).toEqual(["started"]);
    expect(desktopLinkVerdict(r.lines)).toEqual({ up: true, why: "the link came up (up, host_up)" });
    expect(readFileSync(join(dir, "args"), "utf8").trim()).toBe("carrier dial --machine vm_abcdefghij0123456789 --service desktop --deadline-ms 2000");
    // The viewer's hello and start first, then feedback datagrams after `started`.
    const sent = readFileSync(join(dir, "stdin"));
    expect(sent[0]).toBe(1);
    expect(sent.toString("latin1")).toContain('"t":"hello"');
    expect(sent.toString("latin1")).toContain('"t":"start"');
    expect(sent.includes(rdFrame(2, RD_FEEDBACK))).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  }, 15_000);

  test("a dial with no rd_link writes no note, and the verdict says the platform sent none", async () => {
    const { dir, bin } = fakeDesktop(`echo '{"ok":true,"path_state":"relay","route":"carrier"}' >&2
sleep 0.5`);
    const r = await desktopLinkDial(bin, api, "vm_abcdefghij0123456789", 5_000, 2_000);
    expect(r.lines).toEqual([]);
    expect(r.error).toBe("carrier dial: ended while the desktop was open");
    expect(desktopLinkVerdict(r.lines).why).toContain("sent no rd_link");
    rmSync(dir, { recursive: true, force: true });
  });

  test("a refused dial is the error, with no note", async () => {
    const { dir, bin } = fakeDesktop(`echo '{"ok":false,"error_code":"desktop_unavailable"}' >&2
exit 1`);
    const r = await desktopLinkDial(bin, api, "vm_abcdefghij0123456789", 5_000, 2_000);
    expect(r.error).toContain("desktop_unavailable");
    expect(r.lines).toEqual([]);
    rmSync(dir, { recursive: true, force: true });
  });

  test("the verdict names an old image, a failed link, and the wire bytes match cmux-rd-proto", () => {
    expect(desktopLinkVerdict(["cloud.desktop_link machine=vm_x not_answered"]).why).toContain("cmux-rd 0.2.3");
    expect(desktopLinkVerdict(["cloud.desktop_link machine=vm_x answered", "cloud.desktop_link machine=vm_x failed no route"])).toEqual({ up: false, why: "the link did not come up: answered; failed no route" });
    // Header: version 1, kind 7 (Feedback), 14 zero bytes; payload: acked 0, decode 0, no recovery, 0 arrivals, 0 NACKs.
    expect([...RD_FEEDBACK]).toEqual([0x10, 7, ...Array(14).fill(0), ...Array(12).fill(0)]);
    expect([...rdFrame(1, Buffer.from("ab"))]).toEqual([1, 2, 0, 0, 0, 97, 98]);
    expect(maskAddresses("srflx 203.0.113.7:51820 host [2001:db8::1]:4000 vm_ab12")).toBe("srflx <addr> host <addr> vm_ab12");
    expect(teamIdsIn({ personal_team: "team_6b6623866a52063af515" }, null, { team: "team_6b6623866a52063af515" })).toEqual(["team_6b6623866a52063af515"]);
  });
});

describe("cloud journey: leaked machines (--machines, --delete-ids)", () => {
  const now = Date.UTC(2026, 10, 9, 12, 0, 0);
  const H = 3_600_000;
  const id = (n: number) => `vm_${String(n).padStart(20, "0")}`;
  const machine = (over: Record<string, unknown> = {}) => ({ id: id(1), name: "cloud journey jr-mw7vl1n7", status: "paused", created_at: now - 20 * H, last_active_at: now - 19 * H, ...over });

  test("ids are strict vm_ID@JOB_ID entries, at most 5, checked before sign-in", () => {
    expect(parseDeleteEntries(`${id(1)}@128746706182, ${id(2)}@7 ${id(1)}@128746706182`)).toEqual([{ id: id(1), job: "128746706182" }, { id: id(2), job: "7" }]);
    expect(() => parseDeleteEntries("")).toThrow("no machine ids");
    expect(() => parseDeleteEntries(" , ")).toThrow("no machine ids");
    // A bare id has no proof: refused.
    expect(() => parseDeleteEntries(id(1))).toThrow("@<GitHub Actions job id>");
    expect(() => parseDeleteEntries("vm_4817ee90a93468c689d@1")).toThrow("@<GitHub Actions job id>");
    expect(() => parseDeleteEntries(`${id(1)}@1,VM_4817EE90A93468C689D3@1`)).toThrow("@<GitHub Actions job id>");
    expect(() => parseDeleteEntries(`${id(1)}@0`)).toThrow("@<GitHub Actions job id>");
    expect(() => parseDeleteEntries(`${id(1)}@1;rm -rf /`)).toThrow("@<GitHub Actions job id>");
    expect(() => parseDeleteEntries("$(id)@1")).toThrow("@<GitHub Actions job id>");
    expect(() => parseDeleteEntries(`${id(1)}@1,${id(1)}@2`)).toThrow("given twice");
    expect(parseDeleteEntries(Array.from({ length: 5 }, (_, i) => `${id(i)}@1`).join(",")).length).toBe(5);
    expect(() => parseDeleteEntries(Array.from({ length: 6 }, (_, i) => `${id(i)}@1`).join(","))).toThrow("at most 5");
  });

  // cmux-vm run 42485334511, job 128746706182 (deploy-staging): the baseline journey made and deleted vm_962c...,
  // the journey after the deploy made vm_4817... and its cleanup delete got mutation.indeterminate.
  const JOB_LOG = [
    "2026-11-08T13:34:46.6609695Z ##[group]Run bash scripts/cmux-next/cloud-journey-ci.sh",
    "2026-11-08T13:34:47.5710994Z PASS health 886 ms :: commit 0.1.0",
    "2026-11-08T13:34:48.0205834Z PASS sign in (agent test account) 449 ms :: Stack project 454ecd03",
    "2026-11-08T13:34:53.5350164Z PASS create machine 4063 ms :: vm_962c8697bd526edb3c9f status provisioning",
    "2026-11-08T13:35:47.3129035Z PASS delete 1916 ms :: vm_962c8697bd526edb3c9f gone",
    "2026-11-08T13:35:47.3135023Z PASS staging: 25 passed, 0 failed, 3 skipped, 59.2 s",
    "2026-11-08T13:35:58.9523346Z PASS health 852 ms :: commit 0.1.0",
    "2026-11-08T13:35:59.3833812Z PASS sign in (agent test account) 431 ms :: Stack project 454ecd03",
    "2026-11-08T13:36:05.1976698Z PASS create machine 4874 ms :: vm_4817ee90a93468c689d3 status provisioning",
    "2026-11-08T13:36:08.5621120Z PASS listed 69 ms :: 6 machines",
    '2026-11-08T13:36:15.1846422Z FAIL pass Claude login 5250 ms :: exec: HTTP 502 "vm_unavailable"',
    '2026-11-08T13:36:21.9333032Z FAIL delete (cleanup) 6749 ms :: cloud.machine.delete: HTTP 200 {"code":"mutation.indeterminate","message":"the provider call was cut off; retry with the same key","retryable":true}',
    "2026-11-08T13:36:21.9335161Z FAIL staging: 8 passed, 2 failed, 0 skipped, 23.8 s",
  ].join("\r\n");

  test("a job's log proves a leak only with its journey's create of that id and a failed cleanup delete after it", () => {
    expect(leakProof(JOB_LOG, "vm_4817ee90a93468c689d3")).toBeNull();
    // Made and deleted in the same job: no failed cleanup in its own journey.
    expect(leakProof(JOB_LOG, "vm_962c8697bd526edb3c9f")).toContain("logged no failed cleanup delete");
    expect(leakProof(JOB_LOG, id(1))).toContain("no journey that made");
    // A failed cleanup of an earlier journey does not prove a later one's machine.
    const lines = JOB_LOG.split("\r\n");
    const swapped = [...lines.slice(6), ...lines.slice(0, 6)].join("\n");
    expect(leakProof(swapped, "vm_962c8697bd526edb3c9f")).toContain("logged no failed cleanup delete");
    // The cleanup line before the create, or a create outside a journey (no health step), proves nothing.
    expect(leakProof([lines[6], lines[11], lines[8]].join("\n"), "vm_4817ee90a93468c689d3")).not.toBeNull();
    expect(leakProof([lines[8], lines[11]].join("\n"), "vm_4817ee90a93468c689d3")).not.toBeNull();
    // A create that failed, or an id only quoted in another line, proves nothing.
    expect(leakProof([lines[6], lines[8].replace("PASS create", "FAIL create"), lines[11]].join("\n"), "vm_4817ee90a93468c689d3")).not.toBeNull();
    expect(leakProof([lines[6], "PASS listed 1 ms :: vm_4817ee90a93468c689d3", lines[11]].join("\n"), "vm_4817ee90a93468c689d3")).not.toBeNull();
  });

  // The real job and run (fields the proof reads), as the API answered them.
  const TRUSTED_JOB = { id: 128746706182, run_id: 42485334511, name: "deploy-staging", head_branch: "feat-cmux-next", workflow_name: "cmux VM" };
  const TRUSTED_RUN = { id: 42485334511, path: ".github/workflows/cmux-vm.yml", event: "push", head_branch: "feat-cmux-next", repository: { full_name: "manaflow-ai/cmux" }, head_repository: { full_name: "manaflow-ai/cmux" } };
  const gh = (over: { job?: any; run?: any; logStatus?: number; log?: string } = {}) => {
    const calls: Array<{ url: string; auth: string }> = [];
    const get = async (url: string, headers: Record<string, string>) => {
      calls.push({ url, auth: headers.authorization ?? "" });
      const ok = (body: unknown) => ({ status: 200, location: null, text: JSON.stringify(body) });
      if (url.endsWith("/actions/jobs/128746706182")) return ok({ ...TRUSTED_JOB, ...over.job });
      if (url.endsWith("/actions/runs/42485334511")) return ok({ ...TRUSTED_RUN, ...over.run });
      if (url.endsWith("/actions/jobs/128746706182/logs")) return { status: over.logStatus ?? 302, location: "https://blob.example/job-logs.txt?sig=x", text: "" };
      if (url.startsWith("https://blob.example/")) return { status: 200, location: null, text: over.log ?? JOB_LOG };
      return { status: 404, location: null, text: "{}" };
    };
    return { calls, get };
  };
  const entry = { id: "vm_4817ee90a93468c689d3", job: "128746706182" };

  test("the proof: a cmux-vm.yml job of this repo whose log shows the leak; the log link is read without the token", async () => {
    const g = gh();
    expect(await provenLeak(entry, "ghs_token", g.get)).toBeNull();
    expect(g.calls.find((c) => c.url.startsWith("https://blob.example/"))!.auth).toBe("");
    expect(g.calls.filter((c) => c.url.startsWith("https://api.github.com/repos/manaflow-ai/cmux/")).every((c) => c.auth === "Bearer ghs_token")).toBe(true);
  });

  test("proof HTTP failures retain bounded, scrubbed diagnostics without retrying ordinary permission errors", async () => {
    const token = "ghs_proof_secret";
    let calls = 0;
    const reason = await provenLeak(entry, token, async () => {
      calls++;
      return { status: 403, location: null, remaining: "7", text: token + " forbidden " + "x".repeat(400) };
    });
    expect(calls).toBe(1);
    expect(reason).toContain("HTTP 403");
    expect(reason).toContain("x-ratelimit-remaining=7");
    expect(reason).toContain("[secret] forbidden");
    expect(reason).not.toContain(token);
    expect(Buffer.byteLength(JSON.parse(reason!.split("; body=")[1]))).toBe(200);
  });

  test("proof retries each GitHub API read once after its exhausted quota resets", async () => {
    for (const suffix of ["/jobs/128746706182", "/runs/42485334511", "/jobs/128746706182/logs"]) {
      for (const status of [403, 429]) {
        const g = gh();
        let calls = 0;
        const sleeps: number[] = [];
        const get = async (url: string, headers: Record<string, string>) => {
          if (url.endsWith(suffix) && ++calls === 1) return {
            status, location: null, remaining: "0", reset: "102", retryAfter: "3", text: "rate limit exceeded",
          };
          return g.get(url, headers);
        };
        expect(await provenLeak(entry, "ghs_token", get, {
          now: () => 100_000, sleep: async (ms: number) => { sleeps.push(ms); },
        })).toBeNull();
        expect(calls).toBe(2);
        expect(sleeps).toEqual([3000]);
        expect(g.calls.find((c) => c.url.startsWith("https://blob.example/"))!.auth).toBe("");
      }
    }
  });

  test("proof retries are bounded and require an explicit exhausted quota and usable reset", async () => {
    for (const over of [
      { remaining: "0", reset: "102", expectedCalls: 2, expectedSleeps: [2000] },
      { remaining: "0", reset: "500", expectedCalls: 1, expectedSleeps: [] },
      { remaining: "0", reset: undefined, expectedCalls: 1, expectedSleeps: [] },
      { remaining: undefined, reset: "102", expectedCalls: 1, expectedSleeps: [] },
      { remaining: "1", reset: "102", expectedCalls: 1, expectedSleeps: [] },
    ]) {
      let calls = 0;
      const sleeps: number[] = [];
      const reason = await provenLeak(entry, "ghs_token", async () => {
        calls++;
        return { status: 403, location: null, text: "quota exhausted", ...over };
      }, { now: () => 100_000, sleep: async (ms: number) => { sleeps.push(ms); } });
      expect(reason).toContain("HTTP 403");
      expect(reason).toContain("quota exhausted");
      expect(calls).toBe(over.expectedCalls);
      expect(sleeps).toEqual(over.expectedSleeps);
    }
  });

  test("a successful quota retry still rejects an untrusted job", async () => {
    const g = gh({ job: { name: "wake-echo" } });
    let calls = 0;
    const reason = await provenLeak(entry, "ghs_token", async (url, headers) => {
      if (++calls === 1) return { status: 429, location: null, remaining: "0", retryAfter: "1", text: "quota" };
      return g.get(url, headers);
    }, { now: () => 100_000, sleep: async () => {} });
    expect(reason).toContain("is not deploy-staging");
    expect(calls).toBe(2);
  });

  test("a log a contributor's code could have written proves nothing, whatever it prints", async () => {
    // A fork's pull request: the run belongs to this repo and its workflow path is allowed, but the code is the fork's.
    const forkRun = { event: "pull_request", head_branch: "feat-cmux-next", head_repository: { full_name: "someone/cmux" } };
    expect(await provenLeak(entry, "t", gh({ run: forkRun }).get)).toContain("ran code from \"someone/cmux\"");
    expect(await provenLeak(entry, "t", gh({ run: { ...forkRun, path: ".github/workflows/backend.yml" } }).get)).not.toBeNull();
    // A pull request on this repo's own branch, a merge queue, a workflow_run, a pull_request_target: never.
    for (const event of ["pull_request", "pull_request_target", "merge_group", "workflow_run", "schedule", "", undefined]) {
      expect(await provenLeak(entry, "t", gh({ run: { event } }).get)).toContain("runs code a contributor may have written");
    }
    // A push or a dispatch on another branch (a lane branch anyone can push to).
    for (const head_branch of ["lane/x", "feat-cmux-vm-x", "main2"]) {
      expect(await provenLeak(entry, "t", gh({ run: { event: "workflow_dispatch", head_branch }, job: { head_branch } }).get)).toContain("is not feat-cmux-next or main");
    }
    expect(await provenLeak(entry, "t", gh({ run: { event: "workflow_dispatch", head_branch: "main" }, job: { head_branch: "main" } }).get)).toBeNull();
    // The run must be the job's own.
    expect(await provenLeak(entry, "t", gh({ run: { id: 1 } }).get)).toContain("did not read back");
  });

  test("no proof, no delete: another workflow, another repo, an unknown job, an unreadable log, a log without the leak", async () => {
    expect(await provenLeak(entry, "t", gh({ run: { path: ".github/workflows/manual-thing.yml" } }).get)).toContain("is not .github/workflows/cmux-vm.yml");
    expect(await provenLeak(entry, "t", gh({ run: { repository: { full_name: "someone/cmux" } } }).get)).toContain("not in manaflow-ai/cmux");
    expect(await provenLeak({ ...entry, job: "5" }, "t", gh().get)).toContain("HTTP 404");
    expect(await provenLeak(entry, "t", gh({ job: { id: 1 } }).get)).toContain("not a job of");
    expect(await provenLeak(entry, "t", gh({ job: { name: "journey-production" } }).get)).toContain("is not deploy-staging");
    expect(await provenLeak(entry, "t", gh({ logStatus: 410 }).get)).toContain("HTTP 410");
    expect(await provenLeak({ ...entry, id: "vm_962c8697bd526edb3c9f" }, "t", gh().get)).toContain("logged no failed cleanup delete");
  });

  test("the rule: only cloud journey jr-* machines, paused or failed, or old and idle", () => {
    const ok = (m: Record<string, unknown>) => journeyMachineEligible(machine(m), now).eligible;
    // A paused or failed jr- machine (and its gateway) goes.
    expect(ok({})).toBe(true);
    expect(ok({ status: "failed" })).toBe(true);
    expect(ok({ name: "cloud journey jr-mw7vl1n7 gateway" })).toBe(true);
    // An old, idle one goes, running or never active.
    expect(ok({ status: "running", created_at: now - 30 * H, last_active_at: now - 2 * H })).toBe(true);
    expect(ok({ status: "running", created_at: now - 30 * H, last_active_at: null })).toBe(true);
    // Kept never, other names never, whatever their state.
    expect(journeyMachineEligible(machine({ name: "cloud journey kept jr-mw7vl1n7" }), now)).toEqual({ eligible: false, reason: "a kept journey machine" });
    for (const name of ["cloud journey auto jr-mw7vl1n7", "my dev box", "cloud journey jr-", "cloud journey jr-ABC", "x cloud journey jr-abc", "cloud journey jr-abc gateway2", null]) expect(ok({ name })).toBe(false);
    // Running and recent never: made under 24 h ago, or active in the last 45 min.
    expect(ok({ status: "running", created_at: now - 2 * H, last_active_at: null })).toBe(false);
    expect(ok({ status: "running", created_at: now - 30 * H, last_active_at: now - 10 * 60_000 })).toBe(false);
    // A paused machine made under an hour ago may be a journey between its pause and resume.
    expect(ok({ status: "paused", created_at: now - 20 * 60_000 })).toBe(false);
    // In doubt: no.
    for (const status of ["starting", "pausing", "deleting", "deleted", undefined]) expect(ok({ status, created_at: now - 30 * H, last_active_at: null })).toBe(false);
    expect(ok({ created_at: undefined })).toBe(false);
    expect(ok({ created_at: now + H })).toBe(false);
    expect(ok({ status: "running", created_at: now - 30 * H, last_active_at: "yesterday" })).toBe(false);
    expect(ok({ id: "vm_x" })).toBe(false);
  });

  test("a list line carries what the list gives and the rule's answer", () => {
    const line = machineLine(machine({ id: "vm_4817ee90a93468c689d3", error: { code: "e", message: "m", at: 1 } }), "personal", now);
    expect(line).toEqual({ scope: "personal", id: "vm_4817ee90a93468c689d3", name: "cloud journey jr-mw7vl1n7", status: "paused", created: new Date(now - 20 * H).toISOString(), age_h: 20, last_active: new Date(now - 19 * H).toISOString(), pause_reason: null, error: "e", eligible: true, reason: "paused", find_job: expect.stringContaining("vm_4817ee90a93468c689d3@<job id>") });
    expect(machineLine(machine({ name: "cloud journey kept jr-abc" }), "personal", now).find_job).toBeUndefined();
  });

  type Fake = { scope: MachineScope; deletes: string[]; keys: string[] };
  const fake = (rows: any[], answers: Array<{ status: number; body: any }> = [{ status: 200, body: { ok: true, value: {} } }]): Fake => {
    const live = new Map(rows.map((r) => [r.id, { ...r }]));
    const deletes: string[] = [];
    const keys: string[] = [];
    return {
      deletes,
      keys,
      scope: {
        scope: "personal",
        list: async () => [...live.values()],
        get: async (m) => live.get(m) ?? null,
        remove: async (m, key) => {
          deletes.push(m);
          keys.push(key);
          const a = answers.length > 1 ? answers.shift()! : answers[0]!;
          if (a.status === 200 && a.body?.ok) live.get(m)!.status = "deleting";
          return a;
        },
      },
    };
  };
  const deps = (log: string[]) => {
    let t = now;
    return { now: () => t, sleep: async (ms: number) => { t += ms; }, log: (l: string) => log.push(l), retryMs: 180_000, readBackMs: 60_000 };
  };

  test("delete refuses an id the live list lacks, or one the rule does not allow, and then deletes nothing", async () => {
    const f = fake([machine(), machine({ id: id(2), name: "cloud journey kept jr-abc" }), machine({ id: id(3), status: "running", created_at: now - 2 * H })]);
    const log: string[] = [];
    for (const ids of [[id(1), id(9)], [id(1), id(2)], [id(3)]]) {
      const r = await deleteJourneyMachines(ids, [f.scope], "t", deps(log));
      expect(r.deleted).toEqual([]);
      expect(r.failed.length).toBe(1);
    }
    expect(f.deletes).toEqual([]);
    expect(log.some((l) => l.includes("not in the account's machine list"))).toBe(true);
    expect(log.some((l) => l.includes("a kept journey machine"))).toBe(true);
  });

  test("each delete is logged before it is sent, then read back until deleting", async () => {
    const f = fake([machine(), machine({ id: id(2), status: "failed" })]);
    const log: string[] = [];
    const sent: string[] = [];
    const scope = { ...f.scope, remove: async (m: string, k: string) => { sent.push(`delete ${m} after ${log.length} lines`); return f.scope.remove(m, k); } };
    const r = await deleteJourneyMachines([id(1), id(2)], [scope], "t", deps(log));
    expect(r).toEqual({ deleted: [id(1), id(2)], failed: [] });
    expect(JSON.parse(log[0]!)).toEqual({ before_delete: id(1), scope: "personal", name: "cloud journey jr-mw7vl1n7", status: "paused", created: new Date(now - 20 * H).toISOString(), last_active: new Date(now - 19 * H).toISOString() });
    expect(sent[0]).toBe(`delete ${id(1)} after 1 lines`);
    expect(JSON.parse(log[1]!)).toEqual({ deleted: id(1), read_back: "deleting" });
    expect(JSON.parse(log[2]!).before_delete).toBe(id(2));
  });

  test("mutation.indeterminate is retried under the same key, bounded", async () => {
    const indeterminate = { status: 409, body: { ok: false, error: { code: "mutation.indeterminate", retryable: true } } };
    const f = fake([machine()], [indeterminate, indeterminate, { status: 200, body: { ok: true, value: {} } }]);
    const r = await deleteJourneyMachines([id(1)], [f.scope], "t", deps([]));
    expect(r.deleted).toEqual([id(1)]);
    expect(f.keys.length).toBe(3);
    expect(new Set(f.keys).size).toBe(1);
    // Indeterminate for good: it stops at the bound and fails.
    const stuck = fake([machine()], [indeterminate]);
    const s = await deleteJourneyMachines([id(1)], [stuck.scope], "t", deps([]));
    expect(s.deleted).toEqual([]);
    expect(s.failed[0]!.reason).toContain("mutation.indeterminate");
    expect(stuck.deletes.length).toBeGreaterThan(3);
    expect(stuck.deletes.length).toBeLessThan(20);
    // A refusal is final: no retry, no read back.
    const refusedOnce = fake([machine()], [{ status: 409, body: { ok: false, error: { code: "cloud.machine.busy", retryable: false } } }]);
    const r2 = await deleteJourneyMachines([id(1)], [refusedOnce.scope], "t", deps([]));
    expect(r2.failed[0]!.reason).toContain("cloud.machine.busy");
    expect(refusedOnce.deletes.length).toBe(1);
  });

  test("a delete still cut off after its retries is read back, and counts as deleted when it reads deleting or gone", async () => {
    const indeterminate = { status: 409, body: { ok: false, error: { code: "mutation.indeterminate", retryable: true } } };
    for (const after of ["deleting", "gone"] as const) {
      const f = fake([machine()], [indeterminate]);
      let removed = false;
      const log: string[] = [];
      // The provider did delete it; only the answers were cut off.
      const scope = { ...f.scope, remove: async (m: string, k: string) => { removed = true; return f.scope.remove(m, k); }, get: async (m: string) => (removed ? (after === "gone" ? null : { ...machine(), status: "deleting" }) : f.scope.get(m)) };
      const r = await deleteJourneyMachines([id(1)], [scope], "t", deps(log));
      expect(r).toEqual({ deleted: [id(1)], failed: [] });
      expect(JSON.parse(log[log.length - 1]!)).toEqual({ deleted: id(1), read_back: after, after: "mutation.indeterminate" });
    }
    // A transport error the whole time, and the machine is still there: failed, naming both.
    const t = fake([machine()]);
    const down = { ...t.scope, remove: async () => { throw new Error("socket hang up"); } };
    const r = await deleteJourneyMachines([id(1)], [down], "t", deps([]));
    expect(r.failed[0]!.reason).toMatch(/transport.*after the retries, but read back still not gone/);
  });

  test("a machine that changed since the list is checked again right before its delete", async () => {
    const f = fake([machine()]);
    let reads = 0;
    const scope = { ...f.scope, get: async (m: string) => (++reads === 1 ? { ...machine(), status: "running", last_active_at: now } : f.scope.get(m)) };
    const r = await deleteJourneyMachines([id(1)], [scope], "t", deps([]));
    expect(r.deleted).toEqual([]);
    expect(r.failed[0]!.reason).toContain("not eligible at delete time");
    expect(f.deletes).toEqual([]);
  });

  test("each delete ends within its 5 min bound, whatever its requests take: 60 s deletes and 30 s reads", async () => {
    const bound = 180_000 + 120_000;
    // A fake clock and a server whose every delete answers indeterminate after 60 s and every read after 30 s,
    // unless the request's own timeout cuts it first (as AbortSignal.timeout does).
    const run = async (opts: { deleteMs: number; readMs: number; deletes: boolean }) => {
      let t = now;
      const timeouts: number[] = [];
      const slow = async (took: number, timeoutMs: number) => {
        timeouts.push(timeoutMs);
        expect(timeoutMs).toBeGreaterThan(0);
        if (took > timeoutMs) { t += timeoutMs; throw new Error(`timed out after ${timeoutMs} ms`); }
        t += took;
      };
      let removed = false;
      const scope: MachineScope = {
        scope: "personal",
        list: async () => [machine()],
        get: async (_m, timeoutMs) => { await slow(opts.readMs, timeoutMs); return removed ? { ...machine(), status: "deleting" } : machine(); },
        remove: async (_m, _k, timeoutMs) => {
          // From the third attempt on, the provider deletes it; its answer is still cut off.
          if (opts.deletes && t - now > 100_000) removed = true;
          await slow(opts.deleteMs, timeoutMs);
          return { status: 409, body: { ok: false, error: { code: "mutation.indeterminate", retryable: true } } };
        },
      };
      const sleeps: number[] = [];
      const start = t;
      const r = await deleteJourneyMachines([id(1)], [scope], "t", { now: () => t, sleep: async (ms) => { sleeps.push(ms); expect(ms).toBeGreaterThan(0); t += ms; }, log: () => undefined });
      return { r, took: t - start, timeouts, sleeps };
    };
    // Never deleted: the retries and read back run their whole time and stop at the bound, not a request past it.
    for (const [deleteMs, readMs] of [[60_000, 30_000], [59_000, 29_000], [61_000, 31_000], [1_000, 1_000]]) {
      const { r, took, timeouts } = await run({ deleteMs, readMs, deletes: false });
      expect(r.deleted).toEqual([]);
      // A 31 s read is cut at its 30 s timeout: the read before the delete fails, which deletes nothing.
      expect(r.failed[0]!.reason).toMatch(readMs > 30_000 ? /read before delete: timed out after 30000 ms/ : /by its 300 s deadline/);
      expect(took).toBeLessThanOrEqual(bound);
      for (const ms of timeouts) expect(ms).toBeLessThanOrEqual(60_000);
    }
    // Deleted on a late attempt: read back deleting within the bound.
    const late = await run({ deleteMs: 60_000, readMs: 30_000, deletes: true });
    expect(late.r.deleted).toEqual([id(1)]);
    expect(late.took).toBeLessThanOrEqual(bound);
  });

  test("no request or pause starts when less than one whole millisecond of its bound is left", async () => {
    // A clock with fractions of a millisecond, whose reads move it on a little, as time passes between a check and the call.
    const run = async (beforeMs: number) => {
      let t = now;
      const starts: Array<{ kind: string; timeoutMs: number; leftMs: number }> = [];
      // The delete's own start: the clock read just before the read before the delete (each read adds 0.1 ms).
      let retryEnd = Infinity;
      let end = Infinity;
      let reads = 0;
      const scope: MachineScope = {
        scope: "personal",
        list: async () => [machine()],
        get: async (_m, timeoutMs) => {
          if (!reads) { retryEnd = t - 0.1 + 180_000; end = retryEnd + 120_000; }
          starts.push({ kind: reads ? "read" : "before", timeoutMs, leftMs: (reads ? end : retryEnd) - t });
          // The read before the delete takes beforeMs; each read back runs to its timeout.
          t += reads++ ? timeoutMs - 0.3 : beforeMs;
          return machine();
        },
        remove: async (_m, _k, timeoutMs) => {
          starts.push({ kind: "delete", timeoutMs, leftMs: retryEnd - t });
          t += timeoutMs - 0.3;
          return { status: 409, body: { ok: false, error: { code: "mutation.indeterminate", retryable: true } } };
        },
      };
      const sleeps: number[] = [];
      const r = await deleteJourneyMachines([id(1)], [scope], "t", { now: () => (t += 0.1), sleep: async (ms) => { sleeps.push(ms); t += ms; }, log: () => undefined });
      return { r, starts, sleeps, t, end };
    };
    // The read before the delete leaves 0.5 ms of the retry window: no delete is sent at all.
    const a = await run(180_000 - 0.5);
    expect(a.starts.filter((x) => x.kind === "delete")).toEqual([]);
    // Every run: each request starts with at least 1 whole ms left and a timeout of at least 1 ms within it;
    // every pause is at least 1 ms; nothing ends past the bound.
    for (const { starts, sleeps, t, end } of [a, await run(10), await run(29_999.7)]) {
      for (const x of starts) {
        expect(x.timeoutMs).toBeGreaterThanOrEqual(1);
        expect(Number.isInteger(x.timeoutMs)).toBe(true);
        // (0.01 ms of slack for float rounding at epoch-millisecond magnitudes)
        expect(x.leftMs).toBeGreaterThanOrEqual(x.timeoutMs - 0.01);
      }
      for (const ms of sleeps) expect(ms).toBeGreaterThanOrEqual(1);
      expect(t).toBeLessThanOrEqual(end + 1);
    }
  });

  test("a delete that never reads back gone fails", async () => {
    const f = fake([machine()]);
    const scope = { ...f.scope, get: async () => machine() };
    const r = await deleteJourneyMachines([id(1)], [scope], "t", deps([]));
    expect(r.failed[0]!.reason).toContain("read back");
  });
});

describe("clean-room provider key probe", () => {
  const tok = (prefix: string, n = 40) => `${prefix}${"Ab3".repeat(Math.ceil(n / 3)).slice(0, n)}`;
  const OAUTH = tok("sk-ant-oat01-");
  const PROJ = tok("sk-proj-", 32);
  const GEMINI = "AQ.Ab8RN6Jq2ZkVd0wXyP4s";
  const REFRESH = tok("rt_", 30);
  const GEMINI_SHAPE = `AIza${"Q".repeat(35)}`;
  const MISTRAL = "opaqueMistral7Kq2Zr9Lw4";
  const MISTRAL_ARG = "opaqArg8Hx3Np";
  const REFRESH_ENV = tok("rtenv_", 30);
  const REFRESH_ARG = tok("rtarg_", 30);
  const plant = (files: Record<string, string>): string => {
    const root = mkdtempSync(join(tmpdir(), "key-probe-"));
    for (const [rel, text] of Object.entries(files)) {
      const p = join(root, rel);
      mkdirSync(dirname(p), { recursive: true });
      writeFileSync(p, text);
    }
    return root;
  };
  const run = (root: string) => {
    const r = spawnSync("bash", ["-c", keyProbeCommand(readFileSync(KEY_PROBE_PY, "utf8"), ["--root", root, "--budget-s", "20", "--as-root"])], { encoding: "utf8" });
    expect(r.status).toBe(0);
    return { out: r.stdout, probe: parseKeyProbe(r.stdout) };
  };

  test("scrub removes an example of every shape the probe knows", () => {
    // One example per probe shape, by its kind. A shape added to cloud-key-probe.py without an example here fails.
    // Built at run time, like the fixtures above: a key-shaped literal in the source trips push protection.
    const examples: Record<string, string> = {
      "an Anthropic API key": tok("sk-ant-api03-", 24),
      "an Anthropic OAuth token": tok("sk-ant-oat01-", 24),
      "an Anthropic refresh token": tok("sk-ant-ort01-", 24),
      "an OpenAI project key": tok("sk-proj-", 24),
      "an OpenAI service account key": tok("sk-svcacct-", 24),
      "an OpenAI admin key": tok("sk-admin-", 24),
      "an OpenAI user key": `${tok("sk-", 20)}${["T3Bl", "bkFJ"].join("")}${tok("", 20)}`,
      "an OpenRouter key": `sk-or-v1-${"0a1b2c3d".repeat(4)}`,
      "a Google AI key": tok("AIza", 35),
      "an xAI key": tok("xai-", 40),
      "a Groq key": tok("gsk_", 40),
      "a Hugging Face token": tok("hf_", 30),
      "an AWS access key id": tok("AKIA", 16).toUpperCase(),
      "an OAuth refresh token": `"refresh_token": "${tok("", 24)}"`,
    };
    const kinds = [...readFileSync(KEY_PROBE_PY, "utf8").matchAll(/^ {4}\("([^"]+)", re\.compile\(/gm)].map((m) => m[1]);
    expect(kinds.length).toBeGreaterThan(10);
    expect(Object.keys(examples).sort()).toEqual([...kinds].sort());
    for (const [kind, example] of Object.entries(examples)) {
      const out = scrub(`detail: ${example} end`);
      expect(out, kind).toContain("[secret]");
      expect(out, kind).not.toContain(example.replace(/^"refresh_token": "/, "").replace(/"$/, ""));
    }
  });

  test("a key name in any case, a key inside a shell script's words, and a program's unshipped kinds are found", () => {
    const keys = ["Gp8Kz3Af7Le2Do0Ie9Xm4Yn1Wr6Mq5Bt", "Hq9La4Bg8Mf3Ep1Jf0Yn5Zo2Xs7Nr6Cu", "Ir0Mb5Ch9Ng4Fq2Kg1Zo6Ap3Yt8Os7Dv"];
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": `HOME=/root\0openai_api_key=${keys[0]}\0`,
      "proc/5/cmdline": `sh\0-c\0tool --mistral-api-key ${keys[1]} && run\0`,
      "proc/6/comm": "bash\n",
      "proc/6/environ": "HOME=/root\0",
      "proc/6/cmdline": `bash\0-c\0sh -c "export groq_api_key=${keys[2]}; go"\0`,
    });
    // An ELF at a shipped program's place: its Google key shape is shipped, an Anthropic key in it is not.
    const bin = join(root, "home/cmux/.local/share/cmux-tui/builds/b1/bin");
    mkdirSync(bin, { recursive: true });
    const anthropic = "sk-ant-api03-Js1Nc6Di0Oh5Gr3Lh2Ap7Bq4Zu9Pt8Ew";
    const elf = Buffer.alloc(8192);
    Buffer.from("\x7fELF", "latin1").copy(elf, 0);
    Buffer.from("AIzaSy9Kq3Lw7Lx2Mn4Bv8Rt5Hj1Fd6Gc0Pq3Zx").copy(elf, 2000);
    Buffer.from(anthropic).copy(elf, 5000);
    writeFileSync(join(bin, "tool"), elf);
    try {
      const { probe, out } = run(root);
      for (const v of [...keys, anthropic]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "cmdline process bash (1 pid): GROQ_API_KEY",
        "cmdline process bash (1 pid): MISTRAL_API_KEY",
        "env process bash (1 pid): OPENAI_API_KEY (a value)",
        "file /home/cmux/.local/share/cmux-tui/builds/[a name]/bin/[a name]: an Anthropic API key",
      ]);
      expect(probe.shipped.map((f) => f.what)).toEqual(["a Google AI key"]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("names every planted key by place and kind, and prints no value", () => {
    const root = plant({
      "proc/101/comm": "claude\n",
      "proc/101/environ": `ANTHROPIC_API_KEY=cmux-vm-edge-placeholder\0CLAUDE_CODE_OAUTH_TOKEN=${OAUTH}\0PATH=/usr/bin\0`,
      "proc/101/cmdline": "claude\0--print\0",
      "proc/102/comm": "node\n",
      "proc/102/environ": "HOME=/home/cmux\0",
      "proc/102/cmdline": `node\0--key\0${PROJ}\0`,
      // A key named on a command line, in each form: NAME=value, --name=value, --name value, and inside sh -c.
      "proc/103/comm": "env\n",
      "proc/103/environ": "",
      "proc/103/cmdline": "env\0OPENAI_API_KEY=opaque-secret-one\0tool\0",
      "proc/104/comm": "tool\n",
      "proc/104/environ": "",
      "proc/104/cmdline": "tool\0--openai-api-key=opaque2\0--GEMINI_API_KEY\0opaque3\0",
      "proc/105/comm": "sh\n",
      "proc/105/environ": "",
      "proc/105/cmdline": "sh\0-c\0cd /w && XAI_API_KEY=opaque4 run; echo OPENAI_API_KEY=$OPENAI_API_KEY\0",
      // A file and a process named with a key: found, and the name never prints the key.
      [`home/cmux/cache/${PROJ}`]: `${PROJ}\n`,
      "proc/106/comm": `${GEMINI_SHAPE}\n`,
      "proc/106/environ": `CLAUDE_CODE_OAUTH_TOKEN=${OAUTH}\0`,
      "proc/106/cmdline": "x\0",
      // Keys found by context, not shape (a refresh token in JSON, an opaque value of a key's name), named in a path
      // or a process name: found, and the name never prints them either.
      [`home/cmux/cache/${REFRESH}`]: JSON.stringify({ refresh_token: REFRESH }),
      [`home/cmux/cache/${MISTRAL}.env`]: `MISTRAL_API_KEY=${MISTRAL}\n`,
      "proc/107/comm": `${MISTRAL_ARG}\n`,
      "proc/107/environ": "",
      "proc/107/cmdline": `tool\0--mistral-api-key\0${MISTRAL_ARG}\0`,
      "proc/108/comm": "codex\n",
      "proc/108/environ": `CODEX_AUTH_JSON=${JSON.stringify({ tokens: { refresh_token: REFRESH_ENV } })}\0`,
      "proc/108/cmdline": "codex\0",
      [`home/cmux/${REFRESH_ENV}/.codex/auth.json`]: "{}",
      "proc/109/comm": `${REFRESH_ARG}\n`,
      "proc/109/environ": "",
      "proc/109/cmdline": `login\0--json\0{"refresh_token": "${REFRESH_ARG}"}\0`,
      // A key inside node_modules and inside a binary file still counts.
      "home/cmux/app/node_modules/x/.env": `ANTHROPIC_API_KEY=${tok("sk-ant-api03-")}\n`,
      "home/cmux/bin/blob": `\0\0ELF${PROJ}\0\0`,
      // Installed software's bare key shapes (what the image put in /opt, a harness's plugin cache) are listed apart, not
      // counted; a key found by its context (a refresh token's field) counts there too.
      "opt/tool/bin/blob": `\0\0ELF${PROJ}\0\0`,
      "home/cmux/.codex/.tmp/plugins/p/skills/api.md": `call it with ${PROJ}\n`,
      // AWS's documented stand-in is not a key anywhere; a real-shaped id is.
      "home/cmux/aws.txt": "id AKIAIOSFODNN7EXAMPLE\nid AKIA2E0A8F3B244C9986\n",
      "home/cmux/.claude/.credentials.json": JSON.stringify({ claudeAiOauth: { accessToken: OAUTH } }),
      "home/cmux/.codex/auth.json": JSON.stringify({ tokens: { refresh_token: REFRESH } }),
      "home/cmux/.bashrc": `export PATH=$HOME/bin:$PATH\nexport GEMINI_API_KEY=${GEMINI}\n`,
      // The model plane's placeholder and a key named in prose or as a reference are not keys.
      "etc/cmux/model-plane.env": "export OPENAI_API_KEY='cmux-vm-edge-placeholder'\nexport ANTHROPIC_API_KEY='cmux-vm-edge-placeholder'\n",
      "home/cmux/notes.md": "Set OPENAI_API_KEY before you run it: OPENAI_API_KEY=$OPENAI_API_KEY\n",
    });
    try {
      const { out, probe } = run(root);
      for (const v of [OAUTH, PROJ, GEMINI, GEMINI_SHAPE, REFRESH, REFRESH_ENV, REFRESH_ARG, MISTRAL, MISTRAL_ARG, OAUTH.slice(13, 30), PROJ.slice(8, 30), "opaque-secret-one", "opaque2", "opaque3", "opaque4"]) expect(out).not.toContain(v);
      const got = probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort();
      expect(got).toEqual([
        "cmdline process [a process] (1 pid): MISTRAL_API_KEY",
        "cmdline process [a process] (1 pid): an OAuth refresh token",
        "cmdline process env (1 pid): OPENAI_API_KEY",
        "cmdline process node (1 pid): an OpenAI project key",
        "cmdline process sh (1 pid): XAI_API_KEY",
        "cmdline process tool (1 pid): GEMINI_API_KEY",
        "cmdline process tool (1 pid): OPENAI_API_KEY",
        "env process [a process] (1 pid): CLAUDE_CODE_OAUTH_TOKEN (an Anthropic OAuth token)",
        "env process claude (1 pid): CLAUDE_CODE_OAUTH_TOKEN (an Anthropic OAuth token)",
        "env process codex (1 pid): CODEX_AUTH_JSON (an OAuth refresh token)",
        "file /home/cmux/.bashrc:2: GEMINI_API_KEY",
        "file /home/cmux/.claude/.credentials.json: a Claude login file",
        "file /home/cmux/.claude/.credentials.json:1: an Anthropic OAuth token",
        "file /home/cmux/.codex/auth.json: a Codex login file",
        "file /home/cmux/.codex/auth.json:1: an OAuth refresh token",
        "file /home/cmux/[a name].txt:2: an AWS access key id",
        "file /home/cmux/[a secret]/.codex/auth.json: a Codex login file",
        "file /home/cmux/app/node_modules/[a name]/.env:1: ANTHROPIC_API_KEY",
        "file /home/cmux/app/node_modules/[a name]/.env:1: an Anthropic API key",
        "file /home/cmux/bin/[a name]: an OpenAI project key",
        "file /home/cmux/cache/[a name].env:1: MISTRAL_API_KEY",
        "file /home/cmux/cache/[a secret]:1: an OAuth refresh token",
        "file /home/cmux/cache/[a secret]:1: an OpenAI project key",
      ]);
      expect((probe.shipped ?? []).map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /home/cmux/.codex/.tmp/plugins/[a name]/skills/[a name].md:1: an OpenAI project key",
        "file /opt/[a name]/bin/[a name]: an OpenAI project key",
      ]);
      expect(keyProbeDetail(probe)).toStartWith("23 findings: ");
      expect(keyProbeDetail(probe)).toContain("2 key shapes in installed software, not counted");
      expect(keyProbeStatus(probe, true)).toBe("fail");
      expect(keyProbeStatus(probe, false)).toBe("skip");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a clean machine is zero, and the probe's own source never counts as a key", () => {
    const root = plant({
      "proc/7/comm": "bash\n",
      "proc/7/environ": "HOME=/root\0OPENAI_API_KEY=cmux-vm-edge-placeholder\0",
      "proc/7/cmdline": `bash\0-c\0${keyProbeCommand(readFileSync(KEY_PROBE_PY, "utf8"))}\0`,
      "tmp/cloud-key-probe.py": readFileSync(KEY_PROBE_PY, "utf8"),
      "home/cmux/.claude/settings.json": JSON.stringify({ env: { ANTHROPIC_BASE_URL: "https://coderouter.cmux.internal" } }),
    });
    try {
      const { probe } = run(root);
      expect(probe.findings).toEqual([]);
      expect(probe.scanned.processes).toBe(1);
      expect(probe.complete).toBe(true);
      expect(keyProbeDetail(probe)).toStartWith("no provider key (");
      expect(keyProbeStatus(probe, true)).toBe("pass");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("walks folders named like pseudo file systems and follows links, each folder and file once", () => {
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "home/cmux/project/dev/.env": `ANTHROPIC_API_KEY=${tok("sk-ant-api03-")}\n`,
      "home/cmux/project/proc/notes": `${PROJ}\n`,
      "home/cmux/project/sys/x": "nothing here\n",
      // Outside every walked root, reached only through links.
      "usr/share/secret/key.env": `${PROJ}\n`,
      "usr/k": `${PROJ}\n`,
      "workspace/project/.env": `OPENAI_API_KEY=${MISTRAL}\n`,
    });
    // A plugin cache (whose matches are shipped) linking to a workspace, walked before the workspace itself.
    mkdirSync(join(root, "home/cmux/.claude/plugins"), { recursive: true });
    symlinkSync(join(root, "workspace/project"), join(root, "home/cmux/.claude/plugins/project"));
    symlinkSync(join(root, "usr/share/secret"), join(root, "home/cmux/linked"));
    symlinkSync(join(root, "usr/k"), join(root, "home/cmux/k.txt"));
    // A loop back to an ancestor, a second link to the same folder, and a link to nothing.
    symlinkSync(join(root, "home/cmux"), join(root, "home/cmux/project/loop"));
    symlinkSync(join(root, "usr/share/secret"), join(root, "home/cmux/project/again"));
    symlinkSync(join(root, "gone"), join(root, "home/cmux/dangling"));
    try {
      const { probe } = run(root);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /home/cmux/project/dev/.env:1: ANTHROPIC_API_KEY",
        "file /home/cmux/project/dev/.env:1: an Anthropic API key",
        "file /home/cmux/project/proc/[a name]:1: an OpenAI project key",
        "file /usr/[a name]:1: an OpenAI project key",
        "file /usr/share/[a name]/[a name].env:1: an OpenAI project key",
        "file /workspace/project/.env:1: OPENAI_API_KEY",
      ]);
      expect(probe.shipped ?? []).toEqual([]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a hard link in a plugin cache does not class a workspace's key as shipped", () => {
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "workspace/project/.env": `OPENAI_API_KEY=${MISTRAL}\n${PROJ}\n`,
    });
    // The cache is walked first; its name for the file is a second hard link, which realpath does not resolve.
    mkdirSync(join(root, "home/cmux/.claude/plugins/p"), { recursive: true });
    linkSync(join(root, "workspace/project/.env"), join(root, "home/cmux/.claude/plugins/p/.env"));
    try {
      const { probe } = run(root);
      // The cache's name is shipped for the key's shape only; the key's name given a value counts there too.
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /home/cmux/.claude/plugins/[a name]/.env:1: OPENAI_API_KEY",
        "file /workspace/project/.env:1: OPENAI_API_KEY",
        "file /workspace/project/.env:2: an OpenAI project key",
      ]);
      expect((probe.shipped ?? []).map((f) => f.where).sort()).toEqual(["/home/cmux/.claude/plugins/[a name]/.env:2"]);
      // Read once, reported under both names.
      expect(probe.scanned.files).toBe(1);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("the programs cmux and Codex install in a home are shipped, only while they are programs", () => {
    const elf = (text: string) => `\x7fELF\0\0${text}\0`;
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      // As on every fresh staging machine: a secret scanner's known public Google keys, Codex's copy of itself.
      "home/cmux/.local/bin/acpmux": elf(GEMINI_SHAPE),
      "home/cmux/.local/share/cmux-tui/builds/0123abcd/bin/cmux": elf(GEMINI_SHAPE),
      "home/cmux/.codex/tmp/arg0/codex-arg0Ab12/apply_patch": elf(PROJ),
      // The same names holding a script, and a program elsewhere in the home: findings.
      "home/cmux/.local/bin/cmux": `#!/bin/sh\nexport OPENAI_API_KEY=${PROJ}\n`,
      "home/cmux/.local/bin/other": elf(GEMINI_SHAPE),
    });
    try {
      const { probe } = run(root);
      expect(probe.findings.map((f) => `${f.where}: ${f.what}`).sort()).toEqual([
        "/home/cmux/.local/bin/[a name]: a Google AI key",
        "/home/cmux/.local/bin/cmux:2: OPENAI_API_KEY",
        "/home/cmux/.local/bin/cmux:2: an OpenAI project key",
      ]);
      expect((probe.shipped ?? []).map((f) => f.where).sort()).toEqual([
        "/home/cmux/.codex/tmp/arg0/[a name]/apply_patch",
        "/home/cmux/.local/bin/acpmux",
        "/home/cmux/.local/share/cmux-tui/builds/[a name]/bin/cmux",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("an escaped key in JSON and a process name cut to 15 bytes never leave in the answer", () => {
    const ESCAPED = "opaqueRefresh7Kv92Npx5Rq8Lm3Dz";
    const root = plant({
      // Linux keeps a process's name to 15 bytes: the start of the key it was named after.
      "proc/5/comm": `${ESCAPED.slice(0, 15)}\n`,
      "proc/5/environ": `CODEX_AUTH_JSON={"refresh_token":"${ESCAPED}"}\0`,
      "proc/5/cmdline": "tool\0",
      "proc/6/comm": `${MISTRAL.slice(0, 15)}\n`,
      "proc/6/environ": `OPENAI_API_KEY=${MISTRAL}\0`,
      "proc/6/cmdline": "tool\0",
      // The same token, its first letter escaped in the file and spelled plainly in the file's name.
      [`home/cmux/cache/${ESCAPED}`]: `{"refresh_token":"\\u006f${ESCAPED.slice(1)}"}\n`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [ESCAPED, ESCAPED.slice(0, 15), ESCAPED.slice(1), MISTRAL, MISTRAL.slice(0, 15)]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "env process [a process] (1 pid): CODEX_AUTH_JSON (an OAuth refresh token)",
        "env process [a process] (1 pid): OPENAI_API_KEY (a value)",
        "file /home/cmux/cache/[a secret]:1: an OAuth refresh token",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a value on the line after its name is found, and a login file's token never leaves in its path", () => {
    const SPLIT = "opaqueSplit9Hq4Lx7Vn2Kw5Tz";
    const SPLIT_KEY = "opaqueSplitKey3Mv8Rq6Pn";
    const LOGIN = "opaqueLogin4Zr7Kq2Xw9Np";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "home/cmux/token.json": `{\n  "refresh_token":\n    "${SPLIT}"\n}\n`,
      "home/cmux/conf.json": `{"OPENAI_API_KEY":\n "${SPLIT_KEY}"}\n`,
      // The name ends the probe's first 4 MiB read and its value starts the next.
      "home/cmux/big.json": `${"a".repeat((4 << 20) - '{"refresh_token":\n'.length - 1)}\n{"refresh_token":\n"${SPLIT}"}\n`,
      // Its token on the next line, and a folder named after it; and a login file whose token has no shape at all.
      [`home/cmux/${SPLIT}/.codex/auth.json`]: `{"tokens": {"refresh_token":\n "${SPLIT}"}}\n`,
      [`home/cmux/${LOGIN}/.claude/.credentials.json`]: JSON.stringify({ claudeAiOauth: { accessToken: LOGIN } }),
    });
    try {
      const { probe, out } = run(root);
      for (const v of [SPLIT, SPLIT_KEY, LOGIN]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.where}: ${f.what}`).sort()).toEqual([
        "/home/cmux/[a name].json:1: OPENAI_API_KEY",
        "/home/cmux/[a name].json:2: an OAuth refresh token",
        "/home/cmux/[a secret]/.claude/.credentials.json: a Claude login file",
        "/home/cmux/[a secret]/.codex/auth.json: a Codex login file",
        "/home/cmux/[a secret]/.codex/auth.json:1: an OAuth refresh token",
        "/home/cmux/token.json:2: an OAuth refresh token",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("an AWS credentials file's secret and a second hit's split value never leave in a path", () => {
    const AWS = "wJalrXUtnFEMIk7MDENGbPxRfiCYq9Kz4Lw8Vn2B";
    const LATE = "opaqueLate5Rk8Wq3Zn7Mv4Tx";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      [`home/cmux/${AWS}/.aws/credentials`]: `[default]\naws_access_key_id = AKIA${"Q".repeat(16)}\naws_secret_access_key = ${AWS}\n`,
      // A key name first, then a refresh token's field far along the same line, its value on the next.
      "home/cmux/late.json": `{"OPENAI_API_KEY": "", "pad": "${"p".repeat(600)}", "refresh_token":\n "${LATE}"}\n`,
      [`home/cmux/${LATE}/.codex/auth.json`]: "{}",
      "home/cmux/project/settings.ini": `aws_secret_access_key = ${AWS.slice(0, 20)}Zz9${AWS.slice(23)}\n`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [AWS, LATE, AWS.slice(0, 15), LATE.slice(0, 15)]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.where}: ${f.what}`).sort()).toEqual([
        "/home/cmux/[a name].json:1: an OAuth refresh token",
        "/home/cmux/[a secret]/.aws/credentials: an AWS credentials file",
        "/home/cmux/[a secret]/.aws/credentials:2: an AWS access key id",
        "/home/cmux/[a secret]/.aws/credentials:3: AWS_SECRET_ACCESS_KEY",
        "/home/cmux/[a secret]/.codex/auth.json: a Codex login file",
        "/home/cmux/project/[a name].ini:1: AWS_SECRET_ACCESS_KEY",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a long value on a later line is found, a large login file is read whole, and no token-like name leaves", () => {
    const LONG = `opaqueLong${"7Kq2Zr9Lw4".repeat(74)}x`; // 751 characters, longer than any one look ahead
    const BIG = "opaqueBig6Rv3Hx8Nq2Lm5";
    const MISSED = "zq81Hw4Kd9Lm2Px7"; // a token no detector names: shape alone keeps it out of the answer
    const root = plant({
      "proc/5/comm": `${MISSED.slice(0, 15)}\n`,
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "home/cmux/token.json": `{"refresh_token":\n "${LONG}"}\n`,
      [`home/cmux/${LONG.slice(0, 15)}/.codex/auth.json`]: "{}",
      // A valid login file over 1 MiB, its token first.
      [`home/cmux/${BIG}/.claude/.credentials.json`]: JSON.stringify({ claudeAiOauth: { accessToken: BIG }, pad: "p".repeat(2 << 20) }),
      [`home/cmux/${MISSED}/notes.txt`]: `${PROJ}\n`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [LONG.slice(0, 15), LONG.slice(-40), BIG, MISSED, MISSED.slice(0, 15)]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /home/cmux/[a name]/notes.txt:1: an OpenAI project key",
        "file /home/cmux/[a piece of a secret]/.codex/auth.json: a Codex login file",
        "file /home/cmux/[a secret]/.claude/.credentials.json: a Claude login file",
        "file /home/cmux/token.json:1: an OAuth refresh token",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("an unknown credential leaves in no path, whatever its punctuation, and a key without digits is found", () => {
    const AT = "@zq81Hw4Kd9Lm2Px7";
    const NODIGIT = "QxTmRzLpVwNcHsJkYbFdSaGeUiOoPaWs";
    const PLUS = "ab+Zq8~Hw4=Kd9Lm2Px7";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      [`home/cmux/cache/${AT}/.codex/auth.json`]: "{}",
      [`home/cmux/cache/${PLUS}/.codex/auth.json`]: "{}",
      [`home/cmux/${NODIGIT}/.codex/auth.json`]: "{}",
      "home/cmux/project/.env": `MISTRAL_API_KEY=${NODIGIT}\n`,
      // Identifiers after a key's name are not keys.
      "home/cmux/project/config.ts": "const OPENAI_API_KEY = requiredStringValueHere\nGEMINI_API_KEY: DefaultProviderCredentials\n",
    });
    try {
      const { probe, out } = run(root);
      for (const v of [AT.slice(1), NODIGIT, PLUS, PLUS.slice(3)]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.where}: ${f.what}`).sort()).toEqual([
        "/home/cmux/[a secret]/.codex/auth.json: a Codex login file",
        "/home/cmux/cache/[a name]/.codex/auth.json: a Codex login file",
        "/home/cmux/cache/[a name]/.codex/auth.json: a Codex login file",
        "/home/cmux/project/.env:1: MISTRAL_API_KEY",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a place prints only names that cannot be a credential, whatever detection saw", () => {
    const SEP = "c8Jp4k_W9q2Lt-v7X3aM_R6n8Ys"; // an opaque token with separators, under no key's name
    const root = plant({
      "proc/5/comm": `${SEP.slice(0, 15)}\n`,
      "proc/5/environ": `OPENAI_API_KEY=${MISTRAL}\0`,
      "proc/5/cmdline": "tool\0",
      "proc/6/comm": "node\n",
      "proc/6/environ": `OPENAI_API_KEY=${MISTRAL}\0`,
      "proc/6/cmdline": "node\0",
      "home/cmux/session.json": `{"access_token":"${SEP}"}\n`,
      [`home/cmux/${SEP}/.codex/auth.json`]: "{}",
      [`home/cmux/a.b/${SEP.slice(0, 6)}/${SEP.slice(7, 13)}/.codex/auth.json`]: "{}",
      // Any casing of a key's name, and a long refresh token in a binary file.
      "home/cmux/project/.env": "Mistral_Api_Key=Q8h2Fx7Kp9Wm4Rz6Lv3Bn5Nt\n",
      "home/cmux/project/blob.bin": `\0{"refresh_token":"${"Aa8k_".repeat(150)}"}`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [SEP, SEP.slice(0, 15), SEP.slice(0, 6), SEP.slice(7, 13), "Q8h2Fx7Kp9Wm4Rz6Lv3Bn5Nt", "Aa8k_Aa8k_"]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "env process [a process] (1 pid): OPENAI_API_KEY (a value)",
        "env process node (1 pid): OPENAI_API_KEY (a value)",
        "file /home/cmux/[a name]/.codex/auth.json: a Codex login file",
        "file /home/cmux/[a name]/[a name]/[a name]/.codex/auth.json: a Codex login file",
        "file /home/cmux/project/.env:1: MISTRAL_API_KEY",
        "file /home/cmux/project/[a name].bin: an OAuth refresh token",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a mark the probe wrote never shields the rest of a name, and a variable's name is shown only when plain", () => {
    const OPAQUE = "c8Jp4k_W9q2Lt-v7X3aM_R6n8Ys";
    const root = plant({
      "proc/5/comm": "tool\n",
      "proc/5/environ": `CACHE_${OPAQUE}=${PROJ}\0EXTRA_PATH=${PROJ}\0`,
      "proc/5/cmdline": "tool\0",
      "home/cmux/session.json": `{"access_token":"${OPAQUE}"}\n`,
      [`home/cmux/${GEMINI_SHAPE}-${OPAQUE}/.codex/auth.json`]: "{}",
      [`home/cmux/[a name]${OPAQUE}/.codex/auth.json`]: "{}",
    });
    try {
      const { probe, out } = run(root);
      for (const v of [OPAQUE, OPAQUE.slice(0, 15), GEMINI_SHAPE]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "env process tool (1 pid): EXTRA_PATH (an OpenAI project key)",
        "env process tool (1 pid): [a variable] (an OpenAI project key)",
        "file /home/cmux/[a name]/.codex/auth.json: a Codex login file",
        "file /home/cmux/[a name]/.codex/auth.json: a Codex login file",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a credential made only of letters leaves in no name: only listed names print", () => {
    const LOWER = "qzmtwprxvknhfgdcslybuaeioj";
    const UPPER = LOWER.toUpperCase();
    const root = plant({
      [`proc/5/comm`]: `${LOWER.slice(0, 15)}\n`,
      "proc/5/environ": `CACHE_${UPPER}=${PROJ}\0`,
      "proc/5/cmdline": "tool\0",
      "home/cmux/session.json": `{"access_token":"${LOWER}"}\n`,
      [`home/cmux/${LOWER}/.codex/auth.json`]: "{}",
      [`home/cmux/${LOWER.slice(0, 9)}/${LOWER.slice(9, 18)}/${LOWER.slice(18)}.json`]: `${PROJ}\n`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [LOWER, UPPER, LOWER.slice(0, 15), LOWER.slice(0, 9), LOWER.slice(9, 18), LOWER.slice(18)]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "env process [a process] (1 pid): [a variable] (an OpenAI project key)",
        "file /home/cmux/[a name]/.codex/auth.json: a Codex login file",
        "file /home/cmux/[a name]/[a name]/[a name].json:1: an OpenAI project key",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a name's own :digits is not a line number, an ancestor's key is read, and a binary file's held-back hit is checked", () => {
    const DIGITS = "123456789012345678901234567890123456";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      // This test's own process is an ancestor of the probe: its command line here holds a real key.
      [`proc/${process.pid}/comm`]: "supervisor\n",
      [`proc/${process.pid}/environ`]: "HOME=/root\0",
      [`proc/${process.pid}/cmdline`]: "supervisor\0--openai-api-key\0Q8h2Fx7Kp9Wm4Rz6Lv3Bn5Nt\0",
      "home/cmux/session.json": `{"access_token":"opaq:${DIGITS}"}\n`,
      [`home/cmux/opaq:${DIGITS}/.codex/auth.json`]: "{}",
      "home/cmux/project/blob.bin": `\0{"refresh_token":"${"Aa8k_".repeat(120)}\0${PROJ}\0`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [DIGITS, DIGITS.slice(0, 12), "Q8h2Fx7Kp9Wm4Rz6Lv3Bn5Nt"]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "cmdline process [a process] (1 pid): OPENAI_API_KEY",
        "file /home/cmux/[a name]/.codex/auth.json: a Codex login file",
        "file /home/cmux/project/[a name].bin: an OpenAI project key",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("an escaped credential (a shell string's \\\" or JSON's \\u0022) is found as a plain one", () => {
    const refresh = "Zq8Wn3Rt6Lp2Vx9Kb5Hj1Dm4Fc7Gs0Ya";
    const named = "Qz7mRt2Kp9Vw4Xn8Lb3Hc6Jd1Fg5Ys0";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      // What a shell restores to a plain JSON login when it sources the file.
      "workspace/project/.env": `export CODEX_AUTH_JSON="{\\"tokens\\":{\\"refresh_token\\":\\"${refresh}\\"}}"\n`,
      // A JSON string holding JSON, its quotes escaped twice over, and one written as \u0022.
      "workspace/project/settings.json": `{"inner": "{\\\\\\"MISTRAL_API_KEY\\\\\\":\\\\\\"${named}A\\\\\\"}"}\n`,
      "workspace/project/other.json": `{"cfg": "{\\u0022MISTRAL_API_KEY\\u0022:\\u0022${named}B\\u0022}"}\n`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [refresh, `${named}A`, `${named}B`]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/.env:1: an OAuth refresh token",
        "file /workspace/project/[a name].json:1: MISTRAL_API_KEY",
        "file /workspace/project/settings.json:1: MISTRAL_API_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a key's name on one line and its escaped value on the next is found", () => {
    const named = "Hv5Kp8Qx2Lt7Rz4Nw9Bd3Fj6Cm1Gs0Ya";
    const aws = "Wq4Lp9Zt2Kx7Rn5Vb8Hd3Jf6Cm1Gs0YaPe7Tu";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      // The name's line has no escape; the value's line does, so only a later reading of the two lines decodes it.
      "workspace/project/conf.json": `{"MISTRAL_API_KEY":\n "\\u0048${named.slice(1)}"}\n`,
      "workspace/project/aws.json": `{"region": "x",\n  "AWS_SECRET_ACCESS_KEY":\n  "\\u0057${aws.slice(1)}"}\n`,
    });
    try {
      const { probe, out } = run(root);
      for (const v of [named, named.slice(1), aws, aws.slice(1)]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].json:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].json:2: AWS_SECRET_ACCESS_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a YAML block scalar's value is read as the key's value, in a text file and a binary one", () => {
    const literal = "Nc4Tq8Lw2Rk7Zp5Hx9Bv3Jd6Fm1Gs0Ya";
    const folded = "Pe7Xu3Kw9Lq2Rz6Vn8Hb4Jc1Dm5Fg0Ts";
    const inDb = "Ub2Wh6Ky9Pq4Rm7Xs3Lv8Jd1Fn5Gc0Za";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "workspace/project/config.yaml": `MISTRAL_API_KEY: |-\n  ${literal}\nother: 1\n`,
      "workspace/project/more.yml": `cloud:\n  AWS_SECRET_ACCESS_KEY: >+2 # rotated monthly\n      ${folded}\n`,
    });
    const page = Buffer.alloc(8192);
    Buffer.from("SQLite format 3\0").copy(page, 0);
    Buffer.from(`OPENAI_API_KEY: |\n  ${inDb}\n`).copy(page, 3000);
    writeFileSync(join(root, "workspace/project/c.db"), page);
    try {
      const { probe, out } = run(root);
      for (const v of [literal, folded, inDb]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].db: OPENAI_API_KEY",
        "file /workspace/project/[a name].yaml:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].yml:2: AWS_SECRET_ACCESS_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a key's value behind YAML comments, tags and anchors, or nested in another assignment, is read", () => {
    const keys = ["Ra3Vk8Lq2Wz7Np5Tx9Hc4Jb6Dm1Fs0Ge", "Sb4Wl9Mr3Xa8Pq6Uy0Jd5Kc7En2Gt1Hf", "Tc5Xm0Ns4Yb9Qr7Vz1Ke6Ld8Fo3Hu2Ig", "Ud6Yn1Ot5Zc0Rs8Wa2Lf7Me9Gp4Iv3Jh", "Ve7Zo2Pu6Ad1St9Xb3Mg8Nf0Hq5Jw4Ki"];
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "workspace/project/a.yaml": `MISTRAL_API_KEY: # rotated monthly\n  ${keys[0]}\n`,
      "workspace/project/b.yaml": `GROQ_API_KEY: !!str ${keys[1]}\n`,
      "workspace/project/c.yaml": `XAI_API_KEY: &shared !vault |- # note\n  # the value\n  ${keys[2]}\n`,
      "workspace/project/d.js": `const env={MISTRAL_API_KEY:"${keys[3]}"};\n`,
    });
    const page = Buffer.alloc(8192);
    Buffer.from("SQLite format 3\0").copy(page, 0);
    Buffer.from(`cfg={OPENAI_API_KEY:"${keys[4]}"}`).copy(page, 3000);
    writeFileSync(join(root, "workspace/project/e.db"), page);
    try {
      const { probe, out } = run(root);
      for (const v of keys) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].db: OPENAI_API_KEY",
        "file /workspace/project/[a name].js:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].yaml:1: GROQ_API_KEY",
        "file /workspace/project/[a name].yaml:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].yaml:1: XAI_API_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a key set through an index, a call, a Dockerfile, make or fish, or ended by a control byte, is read", () => {
    const keys = ["Wf8Ap3Qv7Be2Tu0Yc4Nh9Og1Ir6Kx5Lj", "Xg9Bq4Rw8Cf3Uv1Zd5Oi0Ph2Js7Ly6Mk", "Yh0Cr5Sx9Dg4Vw2Ae6Pj1Qi3Kt8Mz7Nl", "Zi1Ds6Ty0Eh5Wx3Bf7Qk2Rj4Lu9Na8Om", "Aj2Et7Uz1Fi6Xy4Cg8Rl3Sk5Mv0Ob9Pn", "Bk3Fu8Va2Gj7Yz5Dh9Sm4Tl6Nw1Pc0Qo", "Cl4Gv9Wb3Hk8Za6Ei0Tn5Um7Ox2Qd1Rp", "Dm5Hw0Xc4Il9Ab7Fj1Uo6Vn8Py3Re2Sq", "En6Ix1Yd5Jm0Bc8Gk2Vp7Wo9Qz4Sf3Tr", "Fo7Jy2Ze6Kn1Cd9Hl3Wq8Xp0Ra5Tg4Us"];
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "workspace/project/a.py": `os.environ["MISTRAL_API_KEY"] = "${keys[0]}"\n`,
      "workspace/project/b.js": `process.env['GROQ_API_KEY']='${keys[1]}';\n`,
      "workspace/project/c.py": `os.environ.setdefault("XAI_API_KEY", "${keys[2]}")\n`,
      "workspace/project/d.dockerfile": `FROM base\nENV MISTRAL_API_KEY ${keys[3]}\n`,
      "workspace/project/e.mk": `GROQ_API_KEY ?= ${keys[4]}\n`,
      "workspace/project/f.fish": `set -gx XAI_API_KEY ${keys[5]}\n`,
      // A call whose arguments are on their own lines: the name's line holds no `(`, the value is on the next.
      "workspace/project/i.py": `import os\nos.environ.setdefault(\n    "MISTRAL_API_KEY",\n    "${keys[8]}"\n)\n`,
    });
    // Unquoted values in a binary file, ended by a NUL or by a record's control bytes (a shell-history database row).
    const page = Buffer.alloc(8192);
    Buffer.from("SQLite format 3\0").copy(page, 0);
    Buffer.from(`MISTRAL_API_KEY=${keys[6]}\0\0`).copy(page, 3000);
    writeFileSync(join(root, "workspace/project/g.db"), page);
    const rows = Buffer.alloc(8192);
    Buffer.from("SQLite format 3\0").copy(rows, 0);
    Buffer.from(`export GROQ_API_KEY=${keys[7]}\x01\x05`).copy(rows, 5000);
    Buffer.from(`setdefault(\n  'XAI_API_KEY',\n  '${keys[9]}')`).copy(rows, 6000);
    writeFileSync(join(root, "workspace/project/h.sqlite"), rows);
    try {
      const { probe, out } = run(root);
      for (const v of keys) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].db: MISTRAL_API_KEY",
        "file /workspace/project/[a name].js:1: GROQ_API_KEY",
        "file /workspace/project/[a name].py:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].py:1: XAI_API_KEY",
        "file /workspace/project/[a name].py:3: MISTRAL_API_KEY",
        // An extension the probe does not list is part of the hidden name.
        "file /workspace/project/[a name]: GROQ_API_KEY",
        "file /workspace/project/[a name]: XAI_API_KEY",
        "file /workspace/project/[a name]:1: GROQ_API_KEY",
        "file /workspace/project/[a name]:1: XAI_API_KEY",
        "file /workspace/project/[a name]:2: MISTRAL_API_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("the budget holds inside one large file, and what that file showed is kept", () => {
    const named = "Hv5Kp8Qx2Lt7Rz4Nw9Bd3Fj6Cm1Gs0Ya";
    const dir = mkdtempSync(join(tmpdir(), "key-probe-deadline-"));
    const big = join(dir, "big.db");
    // 1 GiB, sparse: a binary file whose first read holds a key's name and value.
    writeFileSync(big, `\0OPENAI_API_KEY="${named}"\0`);
    spawnSync("truncate", ["-s", "1G", big]);
    const script = `
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
t0 = time.monotonic()
try:
    probe.scan_file(sys.argv[2], t0 + 0.05)
    print(json.dumps({"cut": False}))
except probe.OutOfTime as cut:
    print(json.dumps({"cut": True, "hits": [w for _, w in cut.hits], "s": time.monotonic() - t0}))
`;
    try {
      const r = spawnSync("python3", ["-I", "-c", script, KEY_PROBE_PY, big], { encoding: "utf8" });
      const answer = JSON.parse(r.stdout || "{}");
      expect(answer.cut).toBe(true);
      expect(answer.hits).toEqual(["OPENAI_API_KEY"]);
      // One 4 MiB read past the deadline at most, not the rest of the gigabyte.
      expect(answer.s).toBeLessThan(1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a key that spells a stand-in word by chance is a key; only real stand-ins and AWS's own examples are not", () => {
    // Random keys: a stand-in word inside a run of letters and digits, and EXAMPLE inside a Google key's shape.
    const mistral = "Qd7Kx2TestMn4Lw9Vb3Rz8Hj1Fc6Gs5Yp";
    // A reference word or a stand-in word inside a key, after a separator too: still a key.
    const inside = ["Ab3Qxmyenvironment7Kq2Zr9Lw4Np5", "Ab3Qx-test-7Kq2Zr9Lw4Np5Tg8", "Ab3Qxgetenv7Kq2Zr9Lw4Np5Vh2"];
    // Every credential alphabet: base64 (`+/=`), base64url (`-_`), hex, and any printable character (a password's
    // `~!#&*`).
    const printable = ["ab+Zq8~Hw4=Kd9Lm2Px7", "Ab3!Qx#7Kq2&Zr9*Lw4"];
    const alphabets = ["Qd7+Kx2/Mn4Lw9Vb3Rz8Hj1F==", "Qd7-Kx2_Mn4Lw9Vb3Rz8Hj1Fc6", "0a1b2c3d4e5f60718293a4b5c6d7e8f9"];
    // A bracket inside a key, a key that spells the answer's own field names, and separators inside a quoted key.
    const odd = ["ab+Zq8~Hw4[Kd9Lm2Px7]", "Ab3Qxfindings7Kq2Zr9Lw4Np5", "Qd7,Kx2;Mn4)Lw9}Vb3Rz8"];
    const google = `AIza${"Sy9Kq3EXAMPLEw7Lx2Mn4Bv8Rt5Hj1Fd6Gc0".slice(0, 35)}`;
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "workspace/project/a.env": `MISTRAL_API_KEY=${mistral}\n`,
      "workspace/project/d.env": `GROQ_API_KEY=${inside[0]}\nXAI_API_KEY=${inside[1]}\nDEEPSEEK_API_KEY=${inside[2]}\n`,
      "workspace/project/e.env": `MISTRAL_API_KEY=${printable[0]}\nCOHERE_API_KEY=${printable[1]}\n`,
      "workspace/project/f.env": `TOGETHER_API_KEY=${alphabets[0]}\nFIREWORKS_API_KEY=${alphabets[1]}\nCEREBRAS_API_KEY=${alphabets[2]}\n`,
      "workspace/project/g.env": `PERPLEXITY_API_KEY="${odd[0]}"\nOPENROUTER_API_KEY=${odd[1]}\nDEEPSEEK_API_KEY='${odd[2]}'\n`,
      "workspace/project/b.json": `{"k": "${google}"}\n`,
      // Stand-ins: a word at the value's start or after a separator, and the exact values AWS documents.
      "workspace/project/c.env": [
        "MISTRAL_API_KEY=your-mistral-api-key-here",
        "GROQ_API_KEY=sk-test-0123456789abcdef0123",
        "XAI_API_KEY=placeholder_9f8e7d6c5b4a3210",
        "COHERE_API_KEY=process.env.COHERE_API_KEY_VALUE_1",
        "GROQ_API_KEY=${GROQ_API_KEY_FROM_VAULT_1}",
        "XAI_API_KEY={{ secrets.XAI_API_KEY_1 }}",
        "DEEPSEEK_API_KEY=os.environ.get('DEEPSEEK_API_KEY_1')",
        "AWS_SECRET_ACCESS_KEY: *cache-r2-secret-1",
        "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "id AKIAIOSFODNN7EXAMPLE",
        "",
      ].join("\n"),
    });
    try {
      const { probe, out } = run(root);
      for (const v of [mistral, google, ...inside, ...printable, ...alphabets, ...odd]) expect(out).not.toContain(v);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].env:1: GROQ_API_KEY",
        "file /workspace/project/[a name].env:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].env:1: MISTRAL_API_KEY",
        "file /workspace/project/[a name].env:1: PERPLEXITY_API_KEY",
        "file /workspace/project/[a name].env:1: TOGETHER_API_KEY",
        "file /workspace/project/[a name].env:2: COHERE_API_KEY",
        "file /workspace/project/[a name].env:2: FIREWORKS_API_KEY",
        "file /workspace/project/[a name].env:2: OPENROUTER_API_KEY",
        "file /workspace/project/[a name].env:2: XAI_API_KEY",
        "file /workspace/project/[a name].env:3: CEREBRAS_API_KEY",
        "file /workspace/project/[a name].env:3: DEEPSEEK_API_KEY",
        "file /workspace/project/[a name].env:3: DEEPSEEK_API_KEY",
        "file /workspace/project/[a name].json:1: a Google AI key",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  // 76 MiB of reads: bun's 5 s default killed it on a loaded shared pool runner (base run 44851992457, 2026-11-21).
  test("a text file of one huge line is read in pieces: bounded memory, and a key across a piece's edge is found", { timeout: 60_000 }, () => {
    const dir = mkdtempSync(join(tmpdir(), "key-probe-line-"));
    const big = join(dir, "one-line.txt");
    // 64 MiB with no line break: a key's name across the first read's edge, and one deeper in. The first piece ends
    // OVERLAP bytes before the second read's end (8 MiB - 256).
    const M = 1 << 20;
    const body = Buffer.alloc(64 * M, "abc de ");
    Buffer.from(" MISTRAL_API_KEY=Qd7Kx2Mn4Lw9Vb3Rz8Hj1Fc6Gs5Yp0Ta ").copy(body, 4 * M - 266);
    Buffer.from(" GROQ_API_KEY=Xg9Bq4Rw8Cf3Uv1Zd5Oi0Ph2Js7Ly6Mk ").copy(body, 37 * M);
    writeFileSync(big, body);
    // A file whose only key's `_KEY` is split by the first piece's cut, two bytes each side: no other hit in either
    // piece reads across the cut for it.
    const cut = join(dir, "cut.txt");
    const spaces = Buffer.alloc(12 * M, " ");
    Buffer.from("XAI_API_KEY=Tc5Xm0Ns4Yb9Qr7Vz1Ke6Ld8Fo3Hu2Ig ").copy(spaces, 8 * M - 256 - 2 - "XAI_API".length);
    writeFileSync(cut, spaces);
    const script = `
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
try:
    print(json.dumps([sorted({w for _, w in probe.scan_file(f, time.monotonic() + 20)}) for f in sys.argv[2:]]))
except MemoryError:
    print(json.dumps("MemoryError"))
`;
    try {
      // Under 192 MiB: reading the line whole takes several copies of it.
      const r = spawnSync("bash", ["-c", 'ulimit -v 196608; exec python3 -I -c "$0" "$@"', script, KEY_PROBE_PY, big, cut], { encoding: "utf8" });
      expect(JSON.parse(r.stdout || "null")).toEqual([["GROQ_API_KEY", "MISTRAL_API_KEY"], ["XAI_API_KEY"]]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a line of many escapes that spell no key is read in linear time", { timeout: 60_000 }, () => {
    const dir = mkdtempSync(join(tmpdir(), "key-probe-escapes-"));
    const file = join(dir, "strings.json");
    // 400,000 escaped spaces on one line: each was a reading of the whole line, then a search back to its start
    // (4.7 s at this size, four times that at twice it). Then a key after 20,000 short lines of escapes, on its own line.
    writeFileSync(file, `{"s": "${"\\u0020".repeat(400_000)}"}\n` + `{"s": "${"\\u0020".repeat(50)}"}\n`.repeat(20_000) + `MISTRAL_API_KEY=Ab3Qx7Hw4Kd9Lm2Px7Zq8\n`);
    // The same file at half its size: the bound is this machine's own scan of it, not a fixed number of seconds a
    // loaded runner misses (2.27 s against 1.5 s on a shared pool runner, base run 44851992457). Twice the input
    // takes about twice the time when linear (1.6-2.1x measured) and four times when quadratic (3.8x before #41283).
    const half = join(dir, "half.json");
    writeFileSync(half, `{"s": "${"\\u0020".repeat(200_000)}"}\n` + `{"s": "${"\\u0020".repeat(50)}"}\n`.repeat(10_000) + `MISTRAL_API_KEY=Ab3Qx7Hw4Kd9Lm2Px7Zq8\n`);
    const script = `
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
def timed(path):
    best = None
    for _ in range(2):
        t0 = time.monotonic()
        hits = probe.scan_file(path)
        took = time.monotonic() - t0
        best = took if best is None else min(best, took)
    return hits, best
_, half = timed(sys.argv[3])
hits, full = timed(sys.argv[2])
print(json.dumps({"hits": hits, "s": full, "half": half}))
`;
    try {
      const r = spawnSync("python3", ["-I", "-c", script, KEY_PROBE_PY, file, half], { encoding: "utf8" });
      const answer = JSON.parse(r.stdout || "{}");
      expect(answer.hits).toEqual([[20_002, "MISTRAL_API_KEY"]]);
      expect(answer.s / answer.half).toBeLessThan(3);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a login file of blank lines is read in linear time", () => {
    const dir = mkdtempSync(join(tmpdir(), "key-probe-login-"));
    const file = join(dir, "auth.json");
    writeFileSync(file, "\n".repeat(50_000) + "{}");
    const script = `
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
t0 = time.monotonic()
probe.login_values(sys.argv[2])
print(time.monotonic() - t0)
`;
    try {
      const r = spawnSync("python3", ["-I", "-c", script, KEY_PROBE_PY, file], { encoding: "utf8" });
      expect(Number(r.stdout)).toBeLessThan(0.5);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a huge login file is read only in part, and still names its kind", { timeout: 60_000 }, () => {
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "home/cmux/.codex/auth.json": "{}",
    });
    // 1 GiB, sparse: reading it whole would take a gigabyte of memory.
    spawnSync("truncate", ["-s", "1G", join(root, "home/cmux/.codex/auth.json")]);
    try {
      const r = spawnSync(
        "bash",
        ["-c", `ulimit -v 524288; ${keyProbeCommand(readFileSync(KEY_PROBE_PY, "utf8"), ["--root", root, "--budget-s", "20", "--as-root"])}`],
        { encoding: "utf8" },
      );
      expect(r.status).toBe(0);
      const probe = parseKeyProbe(r.stdout);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`)).toEqual([
        "file /home/cmux/.codex/auth.json: a Codex login file",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("the budget holds across many hits in one file, each with a value left open", () => {
    const named = "Hv5Kp8Qx2Lt7Rz4Nw9Bd3Fj6Cm1Gs0Ya";
    const dir = mkdtempSync(join(tmpdir(), "key-probe-hits-"));
    const many = join(dir, "many.env");
    // 20,000 names whose value is open at the line's end, each read ahead past its line: a key first, then the rest.
    writeFileSync(many, `OPENAI_API_KEY=${named}\n` + "OPENAI_API_KEY=\n".repeat(20_000));
    const script = `
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
t0 = time.monotonic()
try:
    probe.scan_file(sys.argv[2], t0 + 0.05)
    print(json.dumps({"cut": False, "s": time.monotonic() - t0}))
except probe.OutOfTime as cut:
    print(json.dumps({"cut": True, "hits": [w for _, w in cut.hits], "s": time.monotonic() - t0}))
`;
    try {
      const r = spawnSync("python3", ["-I", "-c", script, KEY_PROBE_PY, many], { encoding: "utf8" });
      const answer = JSON.parse(r.stdout || "{}");
      expect(answer.cut).toBe(true);
      expect(answer.hits).toContain("OPENAI_API_KEY");
      expect(answer.s).toBeLessThan(1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("any ASCII character JSON writes as \\u00XX is read as itself, in a text file and a binary one", () => {
    const named = "Hv5Kp8Qx2Lt7Rz4Nw9Bd3Fj6Cm1Gs0Ya";
    const proj = PROJ.replace("sk-", "sk\\u002d");
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "workspace/project/conf.json": `{"OPENAI\\u005fAPI\\u005fKEY":"${named}"}\n`,
    });
    const page = Buffer.alloc(8192);
    Buffer.from("SQLite format 3\0").copy(page, 0);
    Buffer.from(`{"k":"${proj}"}`).copy(page, 3000);
    writeFileSync(join(root, "workspace/project/c.db"), page);
    try {
      const { probe, out } = run(root);
      expect(out).not.toContain(named);
      expect(out).not.toContain(PROJ.slice(8));
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].db: an OpenAI project key",
        "file /workspace/project/[a name].json:1: OPENAI_API_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("in a binary file, a \\u0022-escaped refresh token's field and an escaped one longer than a hit's span are found", () => {
    const short = "Mx4Tq9Ld2Wv7Rk5Ns8Pb3Hz6Jc1Fg0Ya";
    const long = "Aa8k_".repeat(150);
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
    });
    const db = (row: string) => {
      const page = Buffer.alloc(8192);
      Buffer.from("SQLite format 3\0").copy(page, 0);
      Buffer.from(row).copy(page, 4000);
      return page;
    };
    mkdirSync(join(root, "workspace/project"), { recursive: true });
    writeFileSync(join(root, "workspace/project/a.db"), db(`{"inner":"{\\u0022refresh_token\\u0022:\\u0022${short}\\u0022}"}`));
    writeFileSync(join(root, "workspace/project/b.db"), db(JSON.stringify({ inner: JSON.stringify({ refresh_token: long }) })));
    try {
      const { probe, out } = run(root);
      expect(out).not.toContain(short);
      expect(out).not.toContain(long.slice(0, 40));
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /workspace/project/[a name].db: an OAuth refresh token",
        "file /workspace/project/[a name].db: an OAuth refresh token",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a key's name across a binary file's 4 MiB reads counts, and a refresh token's field counts in installed software", () => {
    const opaque = "Wv4Nq8Rt2Lp6Zx9Kb3Hj7Dm5Fc1Gs0";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "opt/tool/.env": `CODEX_AUTH_JSON='{"tokens":{"refresh_token":"${opaque}R"}}'\n`,
    });
    // A binary file whose JSON assignment starts 32 bytes before the first read's end: the value runs into the next.
    const edge = 4 << 20;
    const row = Buffer.from(`{"MISTRAL_API_KEY":"${opaque}B${"q7".repeat(40)}"}`);
    const file = Buffer.alloc(edge + 4096);
    Buffer.from("SQLite format 3\0").copy(file, 0);
    row.copy(file, edge - 32);
    mkdirSync(join(root, "workspace/project"), { recursive: true });
    writeFileSync(join(root, "workspace/project/settings.db"), file);
    try {
      const { probe, out } = run(root);
      expect(out).not.toContain(`${opaque}B`);
      expect(out).not.toContain(`${opaque}R`);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /opt/[a name]/.env:1: an OAuth refresh token",
        "file /workspace/project/[a name].db: MISTRAL_API_KEY",
      ]);
      expect(probe.shipped ?? []).toEqual([]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a key's name given a secret counts in a database file and in installed software's folders", () => {
    const opaque = "Qz7mRt2Kp9Vw4Xn8Lb3Hc6Jd1Fg5Ys0";
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "opt/tool/.env": `OPENAI_API_KEY=${opaque}A\n`,
      "home/cmux/.claude/plugins/custom/.env": `OPENAI_API_KEY=${opaque}B\n`,
    });
    // A SQLite file: a binary page holding a settings row's JSON.
    const page = Buffer.alloc(8192);
    Buffer.from("SQLite format 3\0").copy(page, 0);
    Buffer.from(`{"MISTRAL_API_KEY":"${opaque}C"}`).copy(page, 5000);
    mkdirSync(join(root, "workspace/project"), { recursive: true });
    writeFileSync(join(root, "workspace/project/settings.db"), page);
    try {
      const { probe, out } = run(root);
      for (const tail of ["A", "B", "C"]) expect(out).not.toContain(opaque + tail);
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /home/cmux/.claude/plugins/[a name]/.env:1: OPENAI_API_KEY",
        "file /opt/[a name]/.env:1: OPENAI_API_KEY",
        "file /workspace/project/[a name].db: MISTRAL_API_KEY",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a login file named across a linked folder the walk already read counts, at any depth", () => {
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "home/cmux/cache/auth.json": `{"access_token":"opaqueAccess7Kq2Zr9Lw4"}\n`,
      "home/cmux/gc/gcloud/application_default_credentials.json": `{"refresh_token":"opaqueRefresh8Vb3Np6Ht1"}\n`,
      "workspace/project/README.md": "\n",
    });
    // /home is walked before /workspace: both links lead into folders already read under other names.
    symlinkSync(join(root, "home/cmux/cache"), join(root, "workspace/project/.codex"));
    symlinkSync(join(root, "home/cmux/gc"), join(root, "workspace/project/.config"));
    try {
      const { probe, out } = run(root);
      expect(out).not.toContain("opaqueAccess7Kq2Zr9Lw4");
      expect(out).not.toContain("opaqueRefresh8Vb3Np6Ht1");
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /home/cmux/[a name]/gcloud/application_default_credentials.json:1: an OAuth refresh token",
        "file /workspace/project/.codex/auth.json: a Codex login file",
        "file /workspace/project/.config/gcloud/application_default_credentials.json: a Google Cloud login file",
      ]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a home's login file behind a link to a folder already read still counts, and a project's plugins folder is no cache", () => {
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      "home/cmux/cache/auth.json": `{"access_token":"opaqueAccess7Kq2Zr9Lw4"}\n`,
      "workspace/project/.claude/plugins/custom/.env": `OPENAI_API_KEY=${PROJ}\n`,
      "root/.profile": "\n",
    });
    // /root is walked after /home: its .codex is the cache folder the walk has already read.
    symlinkSync(join(root, "home/cmux/cache"), join(root, "root/.codex"));
    try {
      const { probe, out } = run(root);
      expect(out).not.toContain("opaqueAccess7Kq2Zr9Lw4");
      expect(probe.findings.map((f) => `${f.place} ${f.where}: ${f.what}`).sort()).toEqual([
        "file /root/.codex/auth.json: a Codex login file",
        "file /workspace/project/.claude/plugins/[a name]/.env:1: OPENAI_API_KEY",
        "file /workspace/project/.claude/plugins/[a name]/.env:1: an OpenAI project key",
      ]);
      expect(probe.shipped ?? []).toEqual([]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a key glued into a file's name never leaves in the answer", () => {
    const root = plant({
      "proc/5/comm": "bash\n",
      "proc/5/environ": "HOME=/root\0",
      "proc/5/cmdline": "bash\0",
      [`home/cmux/cache/prefix_${GEMINI_SHAPE}`]: `${GEMINI_SHAPE}\n`,
      [`home/cmux/cache/x${PROJ}y`]: `${PROJ}\n`,
    });
    try {
      const { probe, out: stdout } = run(root);
      for (const v of [GEMINI_SHAPE, PROJ]) expect(stdout).not.toContain(v);
      expect(probe.findings.map((f) => f.what).sort()).toEqual(["a Google AI key", "an OpenAI project key"]);
      expect(probe.complete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("no finding with a gap in what was read is unknown: a clean check fails it", () => {
    const root = plant({ "proc/9/comm": "bash\n", "proc/9/environ": "HOME=/root\0", "proc/9/cmdline": "bash\0", "home/cmux/locked": "x" });
    try {
      // Not root: a gap on its own.
      // python3 straight, not keyProbeCommand: that one takes sudo where it can, and root reads every file.
      const direct = (...args: string[]) => spawnSync("python3", ["-I", KEY_PROBE_PY, "--root", root, ...args], { encoding: "utf8" });
      const notRoot = direct();
      const a = parseKeyProbe(notRoot.stdout);
      if (process.getuid?.() !== 0) {
        expect(a.findings).toEqual([]);
        expect(a.complete).toBe(false);
        expect(a.gaps).toContain("not run as root");
        expect(keyProbeStatus(a, true)).toBe("fail");
        expect(keyProbeStatus(a, false)).toBe("skip");
        expect(keyProbeDetail(a)).toContain("unknown");
      }
      // A process still there whose environment cannot be read, and a file that cannot be read.
      spawnSync("chmod", ["000", join(root, "proc/9/environ"), join(root, "home/cmux/locked")]);
      const b = parseKeyProbe(direct("--as-root").stdout);
      if (process.getuid?.() !== 0) {
        expect(b.complete).toBe(false);
        expect(b.gaps).toEqual(["1 processes unreadable", "1 files unreadable"]);
        expect(keyProbeStatus(b, true)).toBe("fail");
      }
      // A walk that runs out of budget.
      const c = parseKeyProbe(direct("--as-root", "--budget-s", "0").stdout);
      expect(c.truncated).toBe(true);
      expect(keyProbeStatus(c, true)).toBe("fail");
    } finally {
      spawnSync("chmod", ["-R", "u+rwX", root]);
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("scrub removes provider keys from any text the journey records", () => {
    const text = `probe printed ${OAUTH} and ${PROJ} at /x/${GEMINI_SHAPE} and /cache/prefix_${GEMINI_SHAPE}_${tok("hf_", 30)}`;
    const out = scrub(text);
    for (const v of [OAUTH, PROJ, GEMINI_SHAPE, "AIza", "hf_"]) expect(out).not.toContain(v);
    expect(out).toContain("[secret]");
  });

  test("the machine exec route's HTTP request waits as long as the command may run", async () => {
    const waits: (number | undefined)[] = [];
    const api = {
      raw: async (_m: string, route: string, _b?: unknown, timeoutMs?: number) => {
        waits.push(timeoutMs);
        if (route.endsWith("/client-session")) return { status: 501, body: { error: { code: "cloud.provider.unsupported" } } };
        return { status: 200, body: { value: { ok: true, exitCode: 0, stdout: "x", stderr: "" } } };
      },
    } as any;
    await directExec(api, "m1", { secrets: [] } as any)("true", 290_000);
    expect(waits[1]).toBeGreaterThanOrEqual(290_000);
  });

  test("an exec longer than the provider edge holds a request runs as a background request (cut at 125 s)", async () => {
    const seen: { method: string; path: string; after: string | null; identity: string | null; auth: string | null }[] = [];
    let polls = 0;
    const server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(req) {
        const url = new URL(req.url);
        seen.push({ method: req.method, path: url.pathname, after: req.headers.get("x-freestyle-background-after-secs"), identity: req.headers.get("x-freestyle-identity-access-token"), auth: req.headers.get("authorization") });
        if (url.pathname === "/v5/vms/vm-1/exec-await") {
          // The edge's cut: without the header, a request held open past ~120 s answers 524.
          if (req.headers.get("x-freestyle-background-after-secs") !== "60") return new Response("timeout", { status: 524 });
          return Response.json({ requestId: "bg-1" }, { status: 202 });
        }
        if (url.pathname === "/v5/background-requests/bg-1") {
          polls++;
          return polls === 1 ? Response.json({ status: "pending" }, { status: 202 }) : Response.json({ statusCode: 0, stdout: "done\n", stderr: "" });
        }
        return new Response("no", { status: 404 });
      },
    });
    try {
      const base = `http://127.0.0.1:${server.port}`;
      const api = {
        raw: async () => ({ status: 200, body: { ok: true, value: { token: "id-tok", vm_id: "vm-1", linux_user: "cmux", api_base_url: base, expires_at: Date.now() + 900_000 } } }),
      } as any;
      const r = await directExec(api, "m1", { secrets: [] } as any, 1)("sleep 200; echo done", 290_000);
      expect(r).toEqual({ code: 0, stdout: "done\n", stderr: "" });
      expect(seen.map((x) => `${x.method} ${x.path}`)).toEqual(["POST /v5/vms/vm-1/exec-await", "GET /v5/background-requests/bg-1", "GET /v5/background-requests/bg-1"]);
      for (const x of seen) {
        expect(x.identity).toBe("id-tok");
        expect(x.auth).toBeNull();
      }
    } finally {
      server.stop(true);
    }
  });

  test("a background exec whose answer never comes fails as unanswered; a stored refusal keeps its status", async () => {
    const accepted = { status: 202, body: { requestId: "bg-2" } };
    let polls = 0;
    const down = async () => {
      polls++;
      return { status: 503, body: {} };
    };
    await expect(settleBackground(accepted, "http://fs", {}, Date.now() + 5, 1, down, 200)).rejects.toThrow("provider outage");
    expect(polls).toBeGreaterThan(5);
    // Rebake 45960390204 (2026-11-27): 503 to every poll for 9 min while the command ran on; it is waited out.
    let n = 0;
    const overloaded = async () => (++n <= 9 ? { status: 503, body: {} } : { status: 200, body: { statusCode: 0 } });
    expect((await settleBackground(accepted, "http://fs", {}, Date.now() + 5, 1, overloaded, 5_000)).status).toBe(200);
    expect(n).toBe(10);
    const pending = async () => ({ status: 202, body: {} });
    await expect(settleBackground(accepted, "http://fs", {}, Date.now() + 20, 1, pending, 200)).rejects.toThrow("by the deadline");
    const refused = await settleBackground(accepted, "http://fs", {}, Date.now() + 60_000, 1, async () => ({ status: 409, body: { error: "busy" } }));
    expect(refused.status).toBe(409);
    await expect(settleBackground({ status: 202, body: { requestId: "../x" } }, "http://fs", {}, Date.now() + 60_000, 1, down)).rejects.toThrow("names no request");
    const short = { status: 200, body: { statusCode: 0 } };
    expect(await settleBackground(short, "http://fs", {}, Date.now(), 1, down)).toBe(short);
  });

  test("an answer without the marker line is an error, not a clean machine", () => {
    expect(() => parseKeyProbe("python3: command not found\n")).toThrow("printed no answer");
  });
});

// The "session model" step reads what ran from the session's Claude transcript, wherever the agent's Claude
// directory is: ~/.claude, or ~/.config/cmux/claude-team (agent-auth.sh's team and gateway modes on a shared machine).
describe("claudeTranscriptModelsProgram", () => {
  const id = "0b6c2f5e-9d1a-4c3e-8f00-1234567890ab";
  const run = (home: string, env: Record<string, string> = {}) =>
    spawnSync("bash", ["-c", claudeTranscriptModelsProgram(id)], { encoding: "utf8", env: { PATH: process.env.PATH ?? "", HOME: home, ...env } }).stdout;
  const transcript = (dir: string, models: string[]) => {
    const project = join(dir, "projects", "-home-cmux-chats-x");
    spawnSync("mkdir", ["-p", project]);
    writeFileSync(join(project, `${id}.jsonl`), models.map((m) => JSON.stringify({ type: "assistant", message: { model: m, role: "assistant" } })).join("\n") + "\n");
  };
  test("finds the transcript in the claude-team directory a team or gateway agent runs with", () => {
    const home = mkdtempSync(join(tmpdir(), "journey-claude-team-"));
    try {
      transcript(join(home, ".config/cmux/claude-team"), ["claude-sonnet-5-5", "<synthetic>"]);
      expect(transcriptModels(run(home))).toEqual(["claude-sonnet-5-5"]);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
  test("finds it in ~/.claude and in CLAUDE_CONFIG_DIR, and names every model that ran", () => {
    const home = mkdtempSync(join(tmpdir(), "journey-claude-home-"));
    try {
      transcript(join(home, ".claude"), ["claude-haiku-5-5"]);
      transcript(join(home, "elsewhere"), ["claude-opus-5-5"]);
      expect(transcriptModels(run(home)).sort()).toEqual(["claude-haiku-5-5"]);
      expect(transcriptModels(run(home, { CLAUDE_CONFIG_DIR: join(home, "elsewhere") })).sort()).toEqual(["claude-haiku-5-5", "claude-opus-5-5"]);
      expect(transcriptModels(run(join(home, "none")))).toEqual([]);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("a warm-spare refusal names the verb's own error_code and error, else stderr's last line", () => {
    // The shape start_chat_cli.rs `refused` prints before it exits 1 (run 43804741509 recorded only "exit 1").
    const stdout = `${JSON.stringify({ ok: false, error: "the install token names no team", error_code: "team_unresolved" })}\n`;
    expect(warmSpareRefusal({ code: 1, stdout, stderr: "" })).toBe("warm-spare refused (exit 1): team_unresolved: the install token names no team");
    expect(warmSpareRefusal({ code: 64, stdout: "", stderr: "usage: cmux link start-chat ...\nunknown flag --x\n" })).toBe("warm-spare refused (exit 64): unknown flag --x");
    expect(warmSpareRefusal({ code: 1, stdout: "", stderr: "" })).toBe("warm-spare refused (exit 1)");
  });

  test("the preclaim burst warms at client-config's platform_origin, not the API host", async () => {
    // cloud-api forwards a fixed list of platform paths; /v1/cloud/spare/warm is not one, so a warm sent to the API
    // host gets an empty 404 (runs 43804741509 and 43809949753). The app sends it to client-config's platform_origin.
    const dir = mkdtempSync(join(tmpdir(), "preclaim-platform-test-"));
    try {
      const cmux = join(dir, "cmux");
      writeFileSync(cmux, `#!/bin/sh\nprintf '%s\\n' "$@" > "${dir}/argv"\necho '{"ok":false,"error":"stub refused","error_code":"stub"}'\nexit 1\n`, { mode: 0o755 });
      const api: any = {
        origin: "https://cloud-api-staging.cmux.dev",
        bearer: "session-token",
        raw: async (method: string, route: string) => route === "/v1/client-config"
          ? { status: 200, body: { platform_origin: "https://cmux-platform-staging.debussy.workers.dev" } }
          : { status: 200, body: { ok: true } },
      };
      const journey = new Journey(resolveBackend("staging"), null, {}, true);
      const code = runPreclaimBurst({
        backend: resolveBackend("staging"), api, cmux, install: { id: "install-1", token: "install-token" }, account: "user-1/team_0123456789abcdef0123",
        login: `sk-ant-oat01-journeystub-${"a".repeat(48)}`, claims: 2, tag: "t", journey, outDir: null, team: "team_0123456789abcdef0123", user: {},
        fetchJson: async () => ({ status: 200, body: { ok: true, commit: "0123456789abcdef" } }),
      });
      // A failed claim is recorded with its step and the burst goes on to the next (run 43918388959 stopped at claim 2
      // of 20 on one reset); the burst still ends red.
      expect(await code).toBe(1);
      expect(journey.preclaimFailures.map((f) => [f.claim, f.error])).toEqual([
        [0, "warm spare: warm-spare refused (exit 1): stub: stub refused"],
        [1, "warm spare: warm-spare refused (exit 1): stub: stub refused"],
      ]);
      const argv = readFileSync(join(dir, "argv"), "utf8").split("\n");
      const request = JSON.parse(argv[argv.indexOf("--request") + 1]);
      expect(request.platform).toBe("https://cmux-platform-staging.debussy.workers.dev");
      expect(request.scope.platform).toBe("https://cmux-platform-staging.debussy.workers.dev");
      expect(() => clientPlatformOrigin({})).toThrow("client-config names no https platform_origin");
      expect(() => clientPlatformOrigin({ platform_origin: "http://x.test" })).toThrow();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a read that drops while the reply is awaited is not judged, and does not fail the claim", async () => {
    // run 43918388959 claim 2: the session started and the prompt was taken, then a /exec read reset (ECONNRESET).
    const replies: Array<string | Error> = ["@@exit 0", "@@exit 0", new Error("ECONNRESET: The socket connection was closed unexpectedly")];
    const result = await runPreclaimChat(async () => {
      const next = replies.shift();
      if (next === undefined) throw new Error("unexpected extra command");
      if (next instanceof Error) throw next;
      return { code: 0, stdout: next, stderr: "" };
    }, "fixture-session", "Reply once", 1000);
    expect(result.replyMs).toBeNull();
    expect(result.replyNotJudged).toBe("reply wait read failed: ECONNRESET: The socket connection was closed unexpectedly");
  });

  test("a preclaim reply the model refuses is not judged, names the turn's error, and does not fail the claim", async () => {
    // run 43817240410 recorded only "reply wait exit 1"; run 43860687099's turn hit the account's weekly limit after the
    // claim, spare and login all worked. The reply is measured, never gated.
    const replies = ["@@exit 0", "@@exit 0", "@@wait 1\n", '{"kind":"turn_error","error":"You\'ve hit your weekly limit · resets Nov 18, 3am (UTC)"}\n'];
    const result = await runPreclaimChat(async () => {
      const stdout = replies.shift();
      if (stdout === undefined) throw new Error("unexpected extra command");
      return { code: 0, stdout, stderr: "" };
    }, "fixture-session", "Reply once", 1000);
    expect(result.replyMs).toBeNull();
    expect(result.replyNotJudged).toBe("reply wait exit 1: You've hit your weekly limit · resets Nov 18, 3am (UTC)");
    // The agent not starting is a claim-path fact and still fails the claim.
    const refused = runPreclaimChat(async () => ({ code: 0, stdout: "@@exit 1", stderr: "" }), "fixture-session", "Reply once", 1000);
    await expect(refused).rejects.toThrow("preclaim fixture-session: agent start refused");
  });

  test("the burst's gate reads claim-path fields only: a held claim with no reply but its login is not a failure", () => {
    const held = preclaimClaimRecord({ claim: 0, machine: "vm_a", answer: { claim: { behind: true } }, leaseHit: true, postBindLogin: "receipt", firstChatMs: 900, firstReplyMs: null, replyNotJudged: "reply wait exit 1: You've hit your weekly limit" });
    expect(held.reply_not_judged).toBe("reply wait exit 1: You've hit your weekly limit");
    expect(preclaimSummary([held])).toMatchObject({ held_claims: 1, held_failures: 0, replies: 0, replies_not_judged: 1 });
    expect(preclaimRunComplete([held], [], 1)).toBe(true);
    expect(preclaimSummaryMarkdown([held])).toContain("- replies not judged: 1");
    expect(preclaimSummaryMarkdown([held])).not.toContain("weekly limit");
    const noLogin = preclaimClaimRecord({ claim: 1, machine: "vm_b", answer: { claim: { behind: true } }, postBindLogin: "missing", firstReplyMs: 2000 });
    expect(preclaimSummary([noLogin])).toMatchObject({ held_failures: 1 });
  });

  test("a failed claim keeps the claimed machine's facts, scrubbed, in its private row", async () => {
    // run 43824872130 deleted the claimed machine after "reply wait exit 1" and kept nothing that said why.
    const commands: string[] = [];
    const guest = await preclaimGuestFacts(async (command) => {
      commands.push(command);
      return { code: 0, stdout: "== own login\nno\n== acp tail s\nlogin sk-ant-oat01-secret-value expired\n", stderr: "" };
    }, "preclaim-t-0");
    expect(commands[0]).toContain("cmux_agent_has_own_login claude");
    expect(commands[0]).toContain("acp tail 'preclaim-t-0'");
    const record = preclaimFailureRecord(0, new Error("reply wait exit 1"), ["sk-ant-oat01-secret-value"], null, guest);
    expect(record.guest).toContain("== own login\nno");
    expect(record.guest).not.toContain("sk-ant-oat01-secret-value");
    expect(preclaimFailureRecord(0, "x").guest).toBeUndefined();
  });
});

describe("preclaim MET table fields", () => {
  test("preclaim health names a deploy commit only: staging's fixed API version and a refused read say why", () => {
    // Staging's cmux-api answers {ok, environment, version: "0.1.0"} (its deploy config API_VERSION): a version, never a deploy.
    expect(preclaimHealthSnapshot({ status: 200, body: { ok: true, environment: "staging", version: "0.1.0" } })).toEqual({ http_status: 200, outcome: "ok", commit: null, commit_unavailable: "/v1/health names 0.1.0, not a deploy commit" });
    expect(preclaimHealthSnapshot({ status: 503, body: { commit: "c684eb73" } })).toEqual({ http_status: 503, outcome: "error", commit: null, commit_unavailable: "/v1/health answered HTTP 503" });
    expect(preclaimHealthSnapshot({ status: 200, body: { ok: true } }).commit_unavailable).toBe("/v1/health names no deploy commit");
    const api = preclaimHealthSnapshot({ status: 200, body: { version: "0.1.0" } });
    const a = preclaimHealthSnapshot({ status: 200, body: { commit: "aaaaaaa1111" } });
    const b = preclaimHealthSnapshot({ status: 200, body: { commit: "bbbbbbb2222" } });
    expect(preclaimDeployFields(api, api, a, b)).toEqual({ staging_sha: "aaaaaaa1111", staging_sha_unavailable: null, deploy_overlap: true, deploy_overlap_unavailable: null });
    expect(preclaimDeployFields(api, api, b, b)).toMatchObject({ staging_sha: "bbbbbbb2222", deploy_overlap: false });
    expect(preclaimDeployFields(api, api, api, api)).toEqual({
      staging_sha: null,
      staging_sha_unavailable: "platform: /v1/health names 0.1.0, not a deploy commit; api: /v1/health names 0.1.0, not a deploy commit",
      deploy_overlap: null,
      deploy_overlap_unavailable: "no service's /v1/health named a deploy commit both before and after the claim",
    });
  });

  test("preclaim refill-to-ready times the claim's spare from created_at to ready, and says why when it cannot", () => {
    const frame = { t: "ephemeral", stream: "cloud:team_a", event: "cloud.spare.ready", data: { machine: "vm_spare", team: "team_a", at: 4_000 } };
    const row = { status: "running", created_at: 1_000, running_since: 9_000 };
    expect(preclaimRefillToReady(1, "vm_spare", frame, row)).toEqual({ refill_to_ready_ms: 3_000, refill_to_ready_unavailable: null });
    // A spare ready before the journey subscribed arrives as the snapshot, which carries no time: its running_since does.
    expect(preclaimRefillToReady(2, "vm_spare", { t: "snapshot", stream: "cloud:team_a", spares_needing_login: ["vm_spare"] }, row)).toEqual({ refill_to_ready_ms: 8_000, refill_to_ready_unavailable: null });
    expect(preclaimRefillToReady(0, "vm_spare", frame, row).refill_to_ready_unavailable).toBe("claim 0's spare was warmed before the burst, not refilled after a claim");
    expect(preclaimRefillToReady(1, null, null, null).refill_to_ready_unavailable).toBe("warm-spare named no spare (the claim was a cold create)");
    expect(preclaimRefillToReady(1, "vm_spare", { t: "snapshot" }, { created_at: 1_000 }).refill_to_ready_unavailable).toBe("neither the spare.ready frame nor the spare's record carries a ready time");
    expect(preclaimRefillToReady(1, "vm_spare", frame, {}).refill_to_ready_unavailable).toBe("the spare's record has no created_at");
    expect(preclaimRefillToReady(1, "vm_spare", frame, { created_at: 5_000 }).refill_to_ready_ms).toBeNull();
    expect(preclaimRefillImage({ claim: { behind: true } }, "vm_spare", "vm_spare")).toEqual({ refill_image: "behind", refill_image_unavailable: null });
    expect(preclaimRefillImage({ claim: {} }, "vm_spare", "vm_spare")).toEqual({ refill_image: "current", refill_image_unavailable: null });
    expect(preclaimRefillImage({}, "vm_spare", "vm_spare").refill_image_unavailable).toBe("the claim answer has no value.claim to say behind or current");
    expect(preclaimRefillImage({ claim: { behind: true } }, "vm_spare", "vm_other").refill_image_unavailable).toBe("the claim did not take the spare the journey timed");
    expect(preclaimRefillImage({ claim: {} }, null, "vm_cold").refill_image).toBeNull();
  });

  test("preclaim hold minutes at t0 read cloud.plan.get usage, the caller's share first, and never invent a 0", () => {
    expect(preclaimHoldMinutes({ usage: { vm_hours_used: 4, vm_hours_used_by_you: 1.5 } })).toEqual({ hold_minutes_t0: 90, hold_minutes_t0_unavailable: null });
    expect(preclaimHoldMinutes({ usage: { vm_hours_used: 0.25 } })).toEqual({ hold_minutes_t0: 15, hold_minutes_t0_unavailable: null });
    expect(preclaimHoldMinutes({ usage: { vm_hours_used: null, vm_hours_used_by_you: null } })).toEqual({ hold_minutes_t0: null, hold_minutes_t0_unavailable: "cloud.plan.get usage names no machine-hours (the meter has no total for this month)" });
    const refused = preclaimHoldMinutes(new Error("cloud.plan.get: HTTP 403 team_0123456789abcdef0123 secret-token"), ["secret-token"]);
    expect(refused.hold_minutes_t0).toBeNull();
    expect(refused.hold_minutes_t0_unavailable).toBe("cloud.plan.get failed: <host>: HTTP 403 <id> [secret]");
    expect(refused.hold_minutes_t0_unavailable).not.toContain("team_0123456789abcdef0123");
    expect(refused.hold_minutes_t0_unavailable).not.toContain("secret-token");
  });

  test("the MET table spells out every field it cannot fill as unavailable: <reason>", () => {
    const cold = preclaimClaimRecord({ claim: 0, machine: "vm_private", leaseHit: false, firstReplyMs: 900, answer: { stages_ms: [{ step: "bound", ms: 400 }] }, met: { ...preclaimRefillToReady(0, null, null, null), ...preclaimRefillImage({}, null, "vm_private"), post_bind_login_ms: 1_200, post_bind_login_ms_unavailable: null, claim_to_first_text_ms: 3_000, claim_to_first_text_unavailable: null } });
    const md = preclaimMetMarkdown([cold], { claims_expected: 10, hold_minutes_t0: null, hold_minutes_t0_unavailable: "cloud.plan.get usage names no machine-hours (the meter has no total for this month)" });
    expect(md).toContain("| hit rate | 0/1 | 10/10 | no |");
    expect(md).toContain("| refill-to-ready p50 / p90 (behind) | unavailable: claim 0's spare was warmed before the burst, not refilled after a claim | - | - |");
    expect(md).toContain("| post-bind login p90 (hits) | unavailable: no claim was a lease hit | 500 ms | - |");
    expect(md).toContain("| claim-to-first-text p90 | 3000 ms (n=1) | 3300 ms (bound p90 400 + reply p90 900 + 2000) | yes |");
    expect(md).toContain("| hold minutes at t0 | unavailable: cloud.plan.get usage names no machine-hours (the meter has no total for this month) | - | - |");
    expect(md).toContain("| claims | 1 of 10 | 10 | no |");
    expect(md).toContain("unavailable: platform: not read; api: not read");
    expect(md).not.toContain("vm_private");
    expect(md).not.toMatch(/\| 0 ms|: 0 \|/);
    const empty = preclaimMetMarkdown([], { claims_expected: 10, hold_minutes_t0: 12.5, hold_minutes_t0_unavailable: null });
    expect(empty).toContain("| hit rate | unavailable: no claim completed | 10/10 | no |");
    expect(empty).toContain("| claim-to-first-text p90 | unavailable: no claim completed | unavailable: no claim answer named its bound stage | - |");
    expect(empty).toContain("| hold minutes at t0 | 12.5 | - | - |");
    expect(preclaimSummaryMarkdown([cold], [], { claims_expected: 10, hold_minutes_t0: 1, hold_minutes_t0_unavailable: null })).toContain("### MET table");
    expect(preclaimSummaryMarkdown([cold])).not.toContain("### MET table");
  });

  test("runPreclaimBurst records every MET field per claim on a hit burst, and the public table carries no identifier", async () => {
    const dir = mkdtempSync(join(tmpdir(), "preclaim-met-test-"));
    const team = "team_0123456789abcdef0123";
    const spare = "vm_Spare0123456789";
    const frame = { t: "ephemeral", stream: `cloud:${team}`, event: "cloud.spare.ready", data: { machine: spare, team, at: 4_000 } };
    class FakeWire {
      private on: Record<string, Array<(e: unknown) => void>> = {};
      constructor() { framed = false; setTimeout(() => this.emit("open", {}), 0); }
      addEventListener(type: string, fn: (e: unknown) => void) { (this.on[type] ??= []).push(fn); }
      send() { setTimeout(() => { framed = true; this.emit("message", { data: JSON.stringify(frame) }); }, 0); }
      close() {}
      private emit(type: string, e: unknown) { for (const fn of this.on[type] ?? []) fn(e); }
    }
    // The spare's record shows it running only once its frame went out, so the frame (with its `at`) times it.
    let framed = false;
    const realWebSocket = (globalThis as any).WebSocket;
    (globalThis as any).WebSocket = FakeWire;
    try {
      // warm-spare's four answers, by request: the warm names the spare, ready names the copy, installed acks, the receipt holds.
      const cmux = join(dir, "cmux");
      writeFileSync(cmux, `#!/bin/sh\ncat >/dev/null\ncase "$*" in\n  *loginReceipt*) echo '{"installed":true}' ;;\n  *'"installed":'*) echo '{"ok":true}' ;;\n  *'"ready":'*) echo '{"copy":{"generation":"gen-1"}}' ;;\n  *) echo '{"machine":"${spare}"}' ;;\nesac\n`, { mode: 0o755 });
      const guest = (command: string) => command.includes("acp wait") ? "@@wait 0\nThe measured reply." : command.includes("acp ensure") || command.includes("acp send") ? "@@exit 0" : command.includes("own-login") ? "own-login" : "";
      const requestedSizes: unknown[] = [];
      const api: any = {
        origin: "https://cloud-api-staging.cmux.dev",
        bearer: "session-token",
        raw: async (_method: string, route: string, body: any) => route === "/v1/client-config" ? { status: 200, body: { platform_origin: "https://platform.example" } }
          : route === "/v1/health" ? { status: 200, body: { ok: true, environment: "staging", version: "0.1.0" } }
          : route.endsWith("/client-session") ? { status: 501, body: { ok: false, error: { code: "cloud.provider.unsupported" } } }
          : route.endsWith("/exec") ? { status: 200, body: { value: { exitCode: 0, stdout: guest(String(body?.command ?? "")) } } }
          : { status: 200, body: { ok: true } },
        read: async (op: string) => op === "cloud.plan.get" ? { usage: { active: 0, saved: 0, vm_hours_used: 4, vm_hours_used_by_you: 1.5 } } : { status: framed ? "running" : "starting", host: "host-1", created_at: 1_000, running_since: 9_000 },
        op: async (_op: string, params: { size: unknown }) => {
          requestedSizes.push(params.size);
          return { machine: { id: spare, status: "running" }, claim: { behind: true }, stages_ms: [{ step: "claim", ms: 40 }, { step: "bound", ms: 60 }] };
        },
        deleteMachine: async () => undefined,
      };
      // The platform's deploy moves during claim 0 (its health_after reads the new commit), then stays.
      let platformReads = 0;
      const fetchJson = async (_method: string, url: string) => {
        expect(url).toBe("https://platform.example/v1/health");
        return { status: 200, body: { ok: true, commit: platformReads++ === 0 ? "aaaaaaa1111aaaa" : "bbbbbbb2222bbbb" } };
      };
      const rowsPath = join(dir, "rows.json");
      const journey = new Journey(resolveBackend("staging"), dir, {}, true);
      const code = await runPreclaimBurst({
        backend: resolveBackend("staging"), api, cmux, install: { id: "install-1", token: "install-token" }, account: `user-1/${team}`,
        login: `sk-ant-oat01-journeystub-${"a".repeat(48)}`, claims: 2, tag: "t", journey, outDir: dir, privateRowsPath: rowsPath, team, user: {}, fetchJson: fetchJson as never,
      });
      expect(code).toBe(0);
      const written = JSON.parse(readFileSync(rowsPath, "utf8"));
      expect(requestedSizes).toEqual(Array(2).fill({ cpu: 2, memory_mb: 4096, disk_mb: 20480 }));
      expect(written.header.burst).toEqual({ claims_expected: 2, hold_minutes_t0: 90, hold_minutes_t0_unavailable: null });
      const [first, second] = written.rows;
      expect(first.lease_hit).toBe(true);
      expect(first.refill_to_ready_ms).toBeNull();
      expect(first.refill_to_ready_unavailable).toBe("claim 0's spare was warmed before the burst, not refilled after a claim");
      expect(second).toMatchObject({ refill_to_ready_ms: 3_000, refill_to_ready_unavailable: null });
      for (const row of written.rows) {
        expect(row).toMatchObject({ refill_image: "behind", refill_image_unavailable: null, post_bind_login: "receipt", post_bind_login_ms_unavailable: null, claim_to_first_text_unavailable: null });
        expect(row.post_bind_login_ms).toBeGreaterThanOrEqual(0);
        expect(row.claim_to_first_text_ms).toBeGreaterThanOrEqual(row.first_reply_ms);
        expect(row.health_before.commit_unavailable).toBe("/v1/health names 0.1.0, not a deploy commit");
      }
      expect(first).toMatchObject({ staging_sha: "aaaaaaa1111aaaa", deploy_overlap: true, deploy_overlap_unavailable: null });
      expect(second).toMatchObject({ staging_sha: "bbbbbbb2222bbbb", deploy_overlap: false });
      const summary = readFileSync(join(dir, "summary.md"), "utf8");
      expect(summary).toContain("| hit rate | 2/2 | 10/10 | no |");
      expect(summary).toContain("| refill-to-ready p50 / p90 (behind) | 3000 / 3000 ms (n=1) | - | - |");
      expect(summary).toContain("| refill-to-ready p50 / p90 (current) | unavailable: no timed refill took a spare on the current image | - | - |");
      expect(summary).toContain("| hold minutes at t0 | 90 | - | - |");
      expect(summary).toContain("| aaaaaaa1111a | yes |");
      for (const id of [spare, team, "install-1", "host-1", "platform.example"]) expect(summary).not.toContain(id);
    } finally {
      (globalThis as any).WebSocket = realWebSocket;
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("preclaim burst: the claim answer says the hit, the warm's naming is its own field", () => {
  test("a warm that names no spare while the claim path reports one ready: the wait ends, the claim's take is a hit, the warm miss is kept", async () => {
    const dir = mkdtempSync(join(tmpdir(), "preclaim-claim-hit-test-"));
    const team = "team_0123456789abcdef0123";
    const taken = "vm_Taken0123456789";
    const frame = { t: "ephemeral", stream: `cloud:${team}`, event: "cloud.spare.ready", data: { machine: taken, team, at: 4_000 } };
    class FakeWire {
      private on: Record<string, Array<(e: unknown) => void>> = {};
      constructor() { setTimeout(() => this.emit("open", {}), 0); }
      addEventListener(type: string, fn: (e: unknown) => void) { (this.on[type] ??= []).push(fn); }
      send() { setTimeout(() => this.emit("message", { data: JSON.stringify(frame) }), 0); }
      close() {}
      private emit(type: string, e: unknown) { for (const fn of this.on[type] ?? []) fn(e); }
    }
    const realWebSocket = (globalThis as any).WebSocket;
    (globalThis as any).WebSocket = FakeWire;
    try {
      const cmux = join(dir, "cmux");
      const warms = join(dir, "warms");
      writeFileSync(cmux, `#!/bin/sh\ncat >/dev/null\ncase "$*" in\n  *loginReceipt*) echo '{"installed":false}' ;;\n  *) echo x >> '${warms}'; echo '{"ok":true,"machine":null,"fresh":false,"reason":"spare.none"}' ;;\nesac\n`, { mode: 0o755 });
      const guest = (command: string) => command.includes("acp wait") ? "@@wait 0\nThe measured reply." : command.includes("acp ensure") || command.includes("acp send") ? "@@exit 0" : command.includes("own-login") ? "own-login" : "";
      let claims = 0;
      const api: any = {
        origin: "https://cloud-api-staging.cmux.dev",
        bearer: "session-token",
        team,
        raw: async (_method: string, route: string, body: any) => route === "/v1/client-config" ? { status: 200, body: { platform_origin: "https://platform.example" } }
          : route === "/v1/health" ? { status: 200, body: { ok: true, environment: "staging", version: "0.1.0" } }
          : route.endsWith("/client-session") ? { status: 501, body: { ok: false, error: { code: "cloud.provider.unsupported" } } }
          : route.endsWith("/exec") ? { status: 200, body: { value: { exitCode: 0, stdout: guest(String(body?.command ?? "")) } } }
          : { status: 200, body: { ok: true } },
        read: async (op: string) => op === "cloud.plan.get" ? { usage: { active: 0, saved: 0, vm_hours_used: 4 } } : { status: "running", host: "host-1", created_at: 1_000, running_since: 9_000 },
        // Claim 0 takes the ready spare; claim 1 finds none and falls back to a create.
        op: async () => claims++ === 0 ? { machine: { id: taken, status: "running" }, claim: { behind: false } } : { machine: { id: "vm_Cold0123456789", status: "running" }, spare_fallback: "no_spare", spare_skips: {} },
        deleteMachine: async () => undefined,
      };
      const fetchJson = async () => ({ status: 200, body: { ok: true, commit: "aaaaaaa1111aaaa" } });
      const rowsPath = join(dir, "rows.json");
      const journey = new Journey(resolveBackend("staging"), dir, {}, true);
      await runPreclaimBurst({
        backend: resolveBackend("staging"), api, cmux, install: { id: "install-1", token: "install-token" }, account: `user-1/${team}`,
        login: `sk-ant-oat01-journeystub-${"a".repeat(48)}`, claims: 2, tag: "t", journey, outDir: dir, privateRowsPath: rowsPath, team, user: {}, fetchJson: fetchJson as never,
        spareWaitMs: 60_000,
      });
      const written = JSON.parse(readFileSync(rowsPath, "utf8"));
      expect(written.failures).toEqual([]);
      const [hit, cold] = written.rows;
      expect(hit).toMatchObject({ lease_hit: true, warm_named: false, warm_reason: "spare.none", spare_ready_by: "claim_path", cold_after_wait: false, post_bind_login: "post-bind" });
      expect(cold).toMatchObject({ lease_hit: false, warm_named: false, spare_ready_by: "claim_path" });
      // One warm per claim: the claim path's ready frame ended each wait at its first probe.
      expect(readFileSync(warms, "utf8").trim().split("\n")).toHaveLength(2);
      expect(written.header.summary).toMatchObject({ lease_hits: 1, claim_taken: 1, warm_named: 0, warm_missed_hits: 1, cold_creates: 1 });
      const summary = readFileSync(join(dir, "summary.md"), "utf8");
      expect(summary).toContain("- hits the warm did not name (no login attached in advance): 1");
      for (const id of [taken, team, "install-1", "host-1", "platform.example"]) expect(summary).not.toContain(id);
    } finally {
      (globalThis as any).WebSocket = realWebSocket;
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("preclaim burst: the warm and the claim ask one team", () => {
  const token = (claims: Record<string, unknown>) => `eyJhbGciOiJFUzI1NiJ9.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.sig`;

  test("the install token's team claim is the team the Rust warm warms in", () => {
    expect(installTokenTeam(token({ sub: "user_a", team: "team_shared0123456789ab" }))).toBe("team_shared0123456789ab");
    expect(installTokenTeam(token({ sub: "user_a" }))).toBeNull();
    expect(installTokenTeam("not-a-jwt")).toBeNull();
  });

  test("a shared-team install warms that team's pool, so the claim is sent in that team too, and the row says they differed", async () => {
    const dir = mkdtempSync(join(tmpdir(), "preclaim-team-test-"));
    const shared = "team_shared0123456789ab", personal = "team_personal0123456789";
    try {
      const cmux = join(dir, "cmux");
      writeFileSync(cmux, `#!/bin/sh\ncat >/dev/null\necho '{"ok":true,"machine":null,"fresh":false,"reason":"spare.none"}'\n`, { mode: 0o755 });
      const guest = (command: string) => command.includes("acp wait") ? "@@wait 0\nThe measured reply." : command.includes("acp ensure") || command.includes("acp send") ? "@@exit 0" : command.includes("own-login") ? "own-login" : "";
      const claimTeams: Array<string | undefined> = [];
      const api: any = {
        origin: "https://cloud-api-staging.cmux.dev",
        bearer: "session-token",
        raw: async (_method: string, route: string, body: any) => route === "/v1/client-config" ? { status: 200, body: { platform_origin: "https://platform.example" } }
          : route.endsWith("/client-session") ? { status: 501, body: { ok: false, error: { code: "cloud.provider.unsupported" } } }
          : route.endsWith("/exec") ? { status: 200, body: { value: { exitCode: 0, stdout: guest(String(body?.command ?? "")) } } }
          : { status: 200, body: { ok: true } },
        read: async () => ({ status: "running", host: "host-1" }),
        op: async function (this: any) { claimTeams.push(this.team); return { machine: { id: "vm_Taken0123456789", status: "running" }, claim: { behind: false } }; },
        deleteMachine: async () => undefined,
      };
      const rowsPath = join(dir, "rows.json");
      const journey = new Journey(resolveBackend("staging"), dir, {}, true);
      await runPreclaimBurst({
        backend: resolveBackend("staging"), api, cmux, install: { id: "install-1", token: token({ sub: "user-1", team: shared }) }, account: `user-1/${personal}`,
        login: `sk-ant-oat01-journeystub-${"a".repeat(48)}`, claims: 1, tag: "t", journey, outDir: dir, privateRowsPath: rowsPath, user: { personal_team: personal },
        fetchJson: (async () => ({ status: 200, body: { ok: true } })) as never,
      });
      const written = JSON.parse(readFileSync(rowsPath, "utf8"));
      expect(written.failures).toEqual([]);
      expect(claimTeams).toEqual([shared]);
      expect(written.rows[0]).toMatchObject({ warm_team_matches_claim: false, lease_hit: true });
      expect(readFileSync(join(dir, "summary.md"), "utf8")).toContain("- warm's team was the claim's default team: no (claims sent in the warm's team)");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("--ensure-bench times acp ensure on a fresh machine", () => {
  // Claim 4 of run 43873927808: "agent start refused" after ~2 min on a 2-core machine at load 3.9. The bench measures
  // ensure right after boot, once boot settles, and with both cores loaded, so a slow start is timed instead of cut off.
  test("the guest program times one ensure in its own session and stops it", () => {
    const quiet = ensureBenchCommand("bench-1", false);
    expect(quiet).toContain("acp ensure 'bench-1' -m claude --json");
    expect(quiet).toContain("acp stop 'bench-1'");
    expect(quiet).toContain("/proc/loadavg");
    expect(quiet).not.toContain("yes >/dev/null");
    const loaded = ensureBenchCommand("bench-2", true);
    expect(loaded).toContain("yes >/dev/null & y1=$!");
    expect(loaded).toContain("kill $y1 $y2");
  });

  test("a run's answer parses into its timing, exit, load and boot state", () => {
    const stdout = "@@ms 131250\n@@exit 1\n@@load1 3.92\n@@state starting\n@@top 98.0 yes;97.5 yes;12.0 claude\n@@out acp: harness claude did not start\n@@slow\nline a\nline b\n";
    expect(parseEnsureBench(stdout, "loaded", 2)).toEqual({ condition: "loaded", run: 2, ms: 131250, exit: "1", load1: "3.92", state: "starting", top: "98.0 yes;97.5 yes;12.0 claude", output: "acp: harness claude did not start", slow: "line a\nline b" });
    expect(parseEnsureBench("", "boot", 0)).toMatchObject({ ms: null, exit: "none", slow: "" });
  });

  test("the table names each condition's p50 and max and whether any crossed the 120 s exec", () => {
    const runs = [
      parseEnsureBench("@@ms 4000\n@@exit 0\n@@load1 0.5\n@@state running\n@@top 1 x\n@@out ok\n", "settled", 0),
      parseEnsureBench("@@ms 6000\n@@exit 0\n@@load1 0.6\n@@state running\n@@top 1 x\n@@out ok\n", "settled", 1),
      parseEnsureBench("@@ms 125000\n@@exit 0\n@@load1 3.9\n@@state running\n@@top 1 x\n@@out ok\n", "loaded", 0),
    ];
    const md = ensureBenchMarkdown(runs);
    expect(md).toContain("| settled | 2 | 4000 | 6000 | 0 |");
    expect(md).toContain("| loaded | 1 | 125000 | 125000 | 1 |");
    expect(md).toContain("crossed 120 s: 1 of 3");
    expect(md).not.toContain("@@");
  });
});

describe("a preclaim agent start that fails says why", () => {
  // Run 43873927808's claim 4 recorded only "agent start refused": acp ensure's exit, output and time were dropped, and
  // the guest facts kept the journal's tail, which pushed out the own-login and acp tail sections.
  test("the refusal names acp ensure's exit, its output and how long it ran", async () => {
    const refused = runPreclaimChat(async () => ({ code: 0, stdout: "acp: harness claude did not start: spawn failed\n@@exit 1\n", stderr: "" }), "s", "Reply once", 1000);
    await expect(refused).rejects.toThrow(/^preclaim s: agent start refused \(exit 1 after \d+ s\): acp: harness claude did not start: spawn failed$/);
  });

  test("an ensure the exec cut off reads as a timeout, with what it printed so far", async () => {
    const cut = runPreclaimChat(async () => ({ code: 124, stdout: "starting claude", stderr: "" }), "s", "Reply once", 1000);
    await expect(cut).rejects.toThrow(/^preclaim s: agent start refused \(no exit within the 120 s exec, code 124, after \d+ s\): starting claude$/);
  });

  test("a long journal never pushes the own-login and acp sections out of a failure's guest facts", () => {
    const guest = `== own login\nyes\n== acp tail s\n{"kind":"turn_error"}\n== acp list\ns ready\n== journal\n${"x".repeat(120)}\n`.repeat(1) + "j\n".repeat(20_000);
    const record = preclaimFailureRecord(4, new Error("agent start refused"), [], null, guest);
    expect(record.guest).toContain("== own login\nyes");
    expect(record.guest).toContain("== acp tail s");
    expect(record.guest!.length).toBeLessThanOrEqual(12_000);
  });
});

describe("exec probe bench", () => {
  const run = (over: Partial<ExecProbeRun>): ExecProbeRun => ({ condition: "settled", kind: "short", run: 0, nonce: "n0", ms: 300, status: 200, code: "", cause: "", ranOnGuest: null, ...over });

  test("a probe leaves its nonce on the guest before it waits", () => {
    expect(execProbeCommand("p-1", 0)).toBe(`echo p-1 >> ${EXEC_PROBE_NONCES}; echo ok`);
    expect(execProbeCommand("p-2", 20)).toBe(`echo p-2 >> ${EXEC_PROBE_NONCES}; sleep 20; echo ok`);
  });

  test("a request that throws with no answer is kept as a probe with its code, not thrown", async () => {
    const reset = Object.assign(new Error("The socket connection was closed unexpectedly."), { code: "ECONNRESET" });
    const r = await execProbe(async () => { throw reset; }, "p-1", 0);
    expect(r).toMatchObject({ status: null, code: "ECONNRESET", cause: "The socket connection was closed unexpectedly." });
  });

  test("each answer names its hop", async () => {
    const answer = (status: number, body: unknown) => execProbe(async () => ({ status, body }), "p", 0);
    expect(await answer(200, { ok: true, value: { exitCode: 0, stdout: "ok\n", stderr: "" } })).toMatchObject({ status: 200, code: "" });
    const doReset = await answer(503, { ok: false, error: { code: "vm_unavailable", message: "the Cloud service restarted during the call; retry", reason: "restarted" } });
    expect(execProbeHop(run(doReset))).toBe("Worker → CloudDO (restarted)");
    expect(execProbeHop(run(await answer(502, { ok: false, error: { code: "vm_unavailable", message: "the machine did not answer; retry" } })))).toBe("CloudDO → provider exec");
    expect(execProbeHop(run(await answer(524, { raw: "<html>" })))).toBe("edge → Worker (HTTP 524)");
    expect(execProbeHop(run(await answer(200, { ok: true, value: { exitCode: 1, stdout: "", stderr: "x" } })))).toBe("guest command (exit 1)");
    expect(execProbeHop(run({}))).toBeNull();
  });

  test("a stopped machine's row keeps only the fields that say who stopped it", () => {
    const row = { id: "m1", status: "paused", pause_reason: "idle", host: "h", env: { A: "1" }, transport: "direct", spec: { cpu: 2 } };
    expect(machineStopFields(row)).toEqual({ status: "paused", pause_reason: "idle", transport: "direct" });
    expect(machineStopFields({ status: "running", paused_by: "spend_cap" })).toEqual({ status: "running", paused_by: "spend_cap" });
    expect(machineStopFields(null)).toEqual({});
  });

  test("a probe with no answer is placed by whether the guest holds its nonce", () => {
    const lost = [run({ nonce: "a", status: null, code: "ECONNRESET" }), run({ nonce: "b", status: null, code: "ECONNRESET" }), run({ nonce: "c" })];
    const marked = markRanOnGuest(lost, "a\nc\n");
    expect(marked.map((r) => execProbeHop(r))).toEqual(["answer lost after the guest ran it", "request lost before the guest", null]);
    expect(markRanOnGuest(lost, null).map((r) => execProbeHop(r))).toEqual(["no answer; guest nonces unread", "no answer; guest nonces unread", null]);
  });

  test("the table counts failures per condition and kind and lists each one", () => {
    const md = execProbeMarkdown([
      run({ condition: "boot", nonce: "a", ms: 100 }),
      run({ condition: "boot", nonce: "b", ms: 900, status: null, code: "ECONNRESET", cause: "socket | closed", ranOnGuest: true }),
      run({ condition: "settled", kind: "wait", nonce: "c", ms: 20_400 }),
    ]);
    expect(md).toContain("- probes: 3; failed: 1 (no answer: 1, refused: 0)");
    expect(md).toContain("| boot | short | 2 | 1 | 100 | 900 |");
    expect(md).toContain("| settled | wait | 1 | 0 | 20400 | 20400 |");
    expect(md).toContain("| boot | short | 0 | 900 | - | ECONNRESET | yes | answer lost after the guest ran it | socket \\| closed |");
  });
});

describe("a request whose socket drops (run 43927514723: connect_info ECONNRESET 40 ms in)", () => {
  /** A local HTTP server that resets the socket of the first `resets` requests and answers the rest with `{ok:true}`. */
  async function resetting<T>(resets: number, run: (url: string, seen: () => number) => Promise<T>): Promise<T> {
    const { createServer } = await import("node:net");
    let seen = 0;
    const server = createServer((c) => {
      c.on("data", () => {
        seen++;
        if (seen <= resets) return c.resetAndDestroy();
        const body = JSON.stringify({ ok: true, value: { host: "h" } });
        c.end(`HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ${body.length}\r\nconnection: close\r\n\r\n${body}`);
      });
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
    try {
      return await run(`http://127.0.0.1:${(server.address() as { port: number }).port}`, () => seen);
    } finally {
      server.close();
    }
  }

  test("a read is sent once more on a fresh connection and answers", async () => {
    await resetting(1, async (url, seen) => {
      const r = await journeyHttp("POST", `${url}/v1/read`, { op: "cloud.machine.connect_info", params: {} }, {}, 5_000, true);
      expect(r.status).toBe(200);
      expect(r.body.value).toEqual({ host: "h" });
      expect(seen()).toBe(2);
    });
  });

  test("a GET retries by default; a second drop fails naming both", async () => {
    await resetting(1, async (url, seen) => {
      expect((await journeyHttp("GET", `${url}/v1/health`, undefined, {})).status).toBe(200);
      expect(seen()).toBe(2);
    });
    await resetting(2, async (url, seen) => {
      await expect(journeyHttp("GET", `${url}/v1/health`, undefined, {})).rejects.toThrow("sent once more on a fresh connection");
      expect(seen()).toBe(2);
    });
  });

  test("a POST that is not repeatable (an op with no key, an exec) is sent once", async () => {
    await resetting(1, async (url, seen) => {
      await expect(journeyHttp("POST", `${url}/v1/cloud/machines/m/exec`, { command: "true" }, {})).rejects.toThrow();
      expect(seen()).toBe(1);
    });
  });

  test("socketDropped knows a dropped socket from a timeout", () => {
    expect(socketDropped(Object.assign(new TypeError("ECONNRESET: The socket connection was closed unexpectedly."), { code: "ECONNRESET" }))).toBe(true);
    expect(socketDropped(new TypeError("fetch failed", { cause: Object.assign(new Error("other side closed"), { code: "UND_ERR_SOCKET" }) }))).toBe(true);
    expect(socketDropped(new DOMException("The operation timed out.", "TimeoutError"))).toBe(false);
  });
});

describe("the agent's launch credential (cmux#40159)", () => {
  // A fake acpmux on $HOME/.cmux/acpmux/acpmux.sock: answers initialize and session/new, and records what it was sent.
  const FAKE_ACPMUX = `import json, os, socket, sys
path, out = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(1)
c, _ = s.accept(); f = c.makefile('r'); seen = []
for line in f:
    m = json.loads(line); seen.append(m)
    c.sendall((json.dumps({'jsonrpc': '2.0', 'id': m['id'], 'result': {'sessionId': 's-1'} if m['method'] == 'session/new' else {}}) + '\\n').encode())
    if m['method'] == 'session/new':
        break
open(out, 'w').write(json.dumps(seen))
`;
  test("the start sends session/new with the login as _meta.acpmux.credentials, never on a command line", { timeout: 30_000 }, () => {
    // A unix socket path has a 108-byte limit: a short folder, not a long TMPDIR.
    const home = mkdtempSync("/tmp/jl-");
    try {
      mkdirSync(join(home, ".cmux/acpmux"), { recursive: true });
      writeFileSync(join(home, "fake.py"), FAKE_ACPMUX);
      const token = "sk-ant-oat01-journeystub-abc123";
      const program = launchCredentialStartProgram("journey-jr-1", "claude/claude-sonnet-5-5", "CLAUDE_CODE_OAUTH_TOKEN", token);
      expect(program.split("\n")[0]).not.toContain(token);
      const sock = join(home, ".cmux/acpmux/acpmux.sock");
      const script = `python3 -I fake.py ${sock} seen.json & for i in $(seq 50); do [ -S ${sock} ] && break; sleep 0.1; done\n${program}\nwait`;
      const r = spawnSync("bash", ["-c", script], { cwd: home, env: { PATH: process.env.PATH, HOME: home }, encoding: "utf8", timeout: 20_000 });
      expect(r.stdout).toContain("@@session s-1");
      const seen = JSON.parse(readFileSync(join(home, "seen.json"), "utf8"));
      expect(seen.map((m: any) => m.method)).toEqual(["initialize", "session/new"]);
      expect(seen[1].params).toEqual({
        mcpServers: [],
        cwd: home,
        _meta: { acpmux: { name: "journey-jr-1", harness: "claude", model: "claude-sonnet-5-5", credentials: { env: { CLAUDE_CODE_OAUTH_TOKEN: token } } } },
      });
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
  test("a start with no launch credential (a receipt spare's own login) sends session/new with no credentials", { timeout: 30_000 }, () => {
    const home = mkdtempSync("/tmp/jn-");
    try {
      mkdirSync(join(home, ".cmux/acpmux"), { recursive: true });
      writeFileSync(join(home, "fake.py"), FAKE_ACPMUX);
      const program = launchCredentialStartProgram("journey-jr-1", "claude", null, null);
      const sock = join(home, ".cmux/acpmux/acpmux.sock");
      const script = `python3 -I fake.py ${sock} seen.json & for i in $(seq 50); do [ -S ${sock} ] && break; sleep 0.1; done\n${program}\nwait`;
      const r = spawnSync("bash", ["-c", script], { cwd: home, env: { PATH: process.env.PATH, HOME: home }, encoding: "utf8", timeout: 20_000 });
      expect(r.stdout).toContain("@@session s-1");
      const seen = JSON.parse(readFileSync(join(home, "seen.json"), "utf8"));
      expect(seen[1].params).toEqual({ mcpServers: [], cwd: home, _meta: { acpmux: { name: "journey-jr-1", harness: "claude" } } });
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
  // The same fake, but it stays for the first prompt and accepts it, as acpmux's queue_prompt does.
  const FAKE_ACPMUX_PROMPT = `import json, os, socket, sys
path, out, accept = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(1)
c, _ = s.accept(); f = c.makefile('r'); seen = []
def send(m): c.sendall((json.dumps(m) + '\\n').encode())
for line in f:
    m = json.loads(line); seen.append(m)
    if m['method'] == 'session/prompt':
        if accept:
            send({'jsonrpc': '2.0', 'method': '_acpmux/prompt_accepted', 'params': {'sessionId': 's-1', 'promptId': m['params']['_meta']['acpmux']['promptId']}})
        else:
            send({'jsonrpc': '2.0', 'id': m['id'], 'error': {'code': -32000, 'message': 'no'}})
        break
    send({'jsonrpc': '2.0', 'id': m['id'], 'result': {'sessionId': 's-1'} if m['method'] == 'session/new' else {}})
open(out, 'w').write(json.dumps(seen))
`;
  const traceId = "0af7651916cd43dd8448eb211c80319c";
  const runPrompted = (accept: boolean) => {
    const home = mkdtempSync("/tmp/jp-");
    try {
      mkdirSync(join(home, ".cmux/acpmux"), { recursive: true });
      writeFileSync(join(home, "fake.py"), FAKE_ACPMUX_PROMPT);
      const token = "sk-ant-oat01-journeystub-abc123";
      const prompt = "Say \"hi\" and it's done";
      const program = launchCredentialStartProgram("journey-jr-1", "claude/claude-sonnet-5-5", "CLAUDE_CODE_OAUTH_TOKEN", token, prompt, traceId);
      expect(program.split("\n")[0]).not.toContain(token);
      const sock = join(home, ".cmux/acpmux/acpmux.sock");
      const script = `python3 -I fake.py ${sock} seen.json ${accept ? 1 : 0} & for i in $(seq 50); do [ -S ${sock} ] && break; sleep 0.1; done\n${program}\nrc=$?\nwait\nexit $rc`;
      const r = spawnSync("bash", ["-c", script], { cwd: home, env: { PATH: process.env.PATH, HOME: home }, encoding: "utf8", timeout: 20_000 });
      return { r, prompt, seen: JSON.parse(readFileSync(join(home, "seen.json"), "utf8")) };
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  };
  test("with a first prompt, the start sends it on the same link after session/new and waits for acpmux to take it", { timeout: 30_000 }, () => {
    const { r, prompt, seen } = runPrompted(true);
    expect(r.stdout).toContain("@@session s-1");
    expect(r.stdout).toContain("@@prompted");
    expect(r.status).toBe(0);
    expect(seen.map((m: any) => m.method)).toEqual(["initialize", "session/new", "session/prompt"]);
    expect(seen[2].params.sessionId).toBe("s-1");
    expect(seen[2].params.prompt).toEqual([{ type: "text", text: prompt }]);
    expect(seen[2].params._meta.acpmux).toMatchObject({ steer: false, resend: false });
    expect(seen[2].params._meta.acpmux.promptId).toMatch(/^[0-9a-f-]{36}$/);
    // The send's W3C trace id rides the prompt (cmux#55505 perf_trace.rs reads params._meta.traceId).
    expect(seen[2].params._meta.traceId).toBe("0af7651916cd43dd8448eb211c80319c");
  });
  test("the start prints its own marks, in order, which startMarks reads as start_ parts", { timeout: 30_000 }, () => {
    const { r } = runPrompted(true);
    const marks = startMarks(r.stdout);
    expect(Object.keys(marks)).toEqual(["start_connected", "start_initialized", "start_session_new", "start_prompt_accepted"]);
    const v = Object.values(marks);
    for (let i = 1; i < v.length; i++) expect(v[i]).toBeGreaterThanOrEqual(v[i - 1]);
  });
  test("startMarks keeps the first of a retried mark and ignores other lines", () => {
    expect(startMarks("@@mark connected 5\n@@retry x\n@@mark connected 2100\n@@mark session_new 9000\nnoise @@mark x 1\n")).toEqual({ start_connected: 5, start_session_new: 9000 });
  });
  test("a trace id that is not 32 lowercase hex never reaches the program", () => {
    const program = launchCredentialStartProgram("s", "claude", "CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-x", "hi", "x'; rm -rf /; '");
    expect(program).toContain("trace = None");
    expect(program).not.toContain("rm -rf");
  });
  test("a refused first prompt is a red after the session started, never a second start", { timeout: 30_000 }, () => {
    const { r, seen } = runPrompted(false);
    expect(r.stdout).toContain("@@session s-1");
    expect(r.stdout).toContain("@@noprompt");
    expect(r.stdout).not.toContain("@@prompted");
    expect(r.status).toBe(2);
    expect(seen.filter((m: any) => m.method === "session/new")).toHaveLength(1);
  });
  // Run 45881843733 (own-host microVM, 2026-11-26): session/new came back daemon.restarting, retryable, "Send the
  // request again in a few seconds", and the start gave up as @@nostart. It sends again now, and still stops on a
  // refusal that is not retryable.
  const FAKE_ACPMUX_RESTARTING = String.raw`
import json, os, socket, sys, time
path, out, mode = sys.argv[1], sys.argv[2], sys.argv[3]
if mode == 'late':
    # acpmux mid-restart: a socket file nobody listens on (ECONNREFUSED, run 45882763507), then the new daemon.
    stale = socket.socket(socket.AF_UNIX); stale.bind(path); stale.close()
    time.sleep(1.5)
    os.unlink(path)
srv = socket.socket(socket.AF_UNIX); srv.bind(path); srv.listen(4)
seen = []
news = 0
while True:
    c, _ = srv.accept(); f = c.makefile('r')
    def send(m): c.sendall((json.dumps(m) + '\n').encode())
    done = False
    for line in f:
        m = json.loads(line); seen.append(m['method'])
        if m['method'] == 'session/prompt':
            # Run 45883411021: acpmux restarted between the start and its first prompt.
            seen[-1] += ':' + m['params']['_meta']['acpmux']['promptId']
            prompts = sum(1 for x in seen if x.startswith('session/prompt'))
            if prompts == 1:
                send({'jsonrpc': '2.0', 'id': m['id'], 'error': {'code': -32000, 'message': 'acpmux is restarting', 'data': {'errorKind': 'daemon.restarting', 'retryable': True}}})
                break
            send({'jsonrpc': '2.0', 'method': '_acpmux/prompt_accepted', 'params': {'sessionId': 's-2', 'promptId': m['params']['_meta']['acpmux']['promptId']}})
            done = True
            break
        if m['method'] == '_acpmux/resolve':
            send({'jsonrpc': '2.0', 'id': m['id'], 'result': {'session': {'sessionId': 's-1', 'name': m['params']['query']}}})
            done = True
            break
        if m['method'] == 'session/new':
            news += 1
            if mode == 'made-then-cut':
                # Run 45885585817: the first start made the session, then acpmux restarted before it answered.
                if news == 1:
                    send({'jsonrpc': '2.0', 'id': m['id'], 'error': {'code': -32000, 'message': 'acpmux is restarting', 'data': {'errorKind': 'daemon.restarting', 'retryable': True}}})
                else:
                    send({'jsonrpc': '2.0', 'id': m['id'], 'error': {'code': -32602, 'message': 'session name "s" is taken'}})
                continue
            if mode == 'taken':
                send({'jsonrpc': '2.0', 'id': m['id'], 'error': {'code': -32602, 'message': 'session name "s" is taken'}})
                done = True
                break
            if news == 1 and mode not in ('late', 'prompt-cut'):
                data = {'errorKind': 'daemon.restarting', 'retryable': True} if mode == 'retryable' else {'errorKind': 'refused', 'retryable': False}
                send({'jsonrpc': '2.0', 'id': m['id'], 'error': {'code': -32000, 'message': 'acpmux is restarting', 'data': data}})
                done = mode != 'retryable'
                break
            send({'jsonrpc': '2.0', 'id': m['id'], 'result': {'sessionId': 's-2'}})
            done = mode != 'prompt-cut'
            if done:
                break
            continue
        send({'jsonrpc': '2.0', 'id': m['id'], 'result': {}})
    c.close()
    if done:
        break
open(out, 'w').write(json.dumps(seen))
`;
  const runRestarting = (mode: "retryable" | "refused" | "late" | "prompt-cut" | "made-then-cut" | "taken") => {
    const home = mkdtempSync("/tmp/jr-");
    try {
      mkdirSync(join(home, ".cmux/acpmux"), { recursive: true });
      writeFileSync(join(home, "fake.py"), FAKE_ACPMUX_RESTARTING);
      const sock = join(home, ".cmux/acpmux/acpmux.sock");
      const program = launchCredentialStartProgram("s", "claude", "CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-x", mode === "prompt-cut" ? "hi" : undefined);
      const script = `python3 -I fake.py ${sock} seen.json ${mode} & for i in $(seq 50); do [ -S ${sock} ] && break; sleep 0.1; done\n${program}\nrc=$?\nwait\nexit $rc`;
      const r = spawnSync("bash", ["-c", script], { cwd: home, env: { PATH: process.env.PATH, HOME: home }, encoding: "utf8", timeout: 20_000 });
      return { r, seen: JSON.parse(readFileSync(join(home, "seen.json"), "utf8")) as string[] };
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  };
  test("a start cut by acpmux's restart (retryable) is sent again and starts", { timeout: 30_000 }, () => {
    const { r, seen } = runRestarting("retryable");
    expect(r.stdout).toContain("@@retry ");
    expect(r.stdout).toContain("@@session s-2");
    expect(r.status).toBe(0);
    expect(seen.filter((m) => m === "session/new")).toHaveLength(2);
  });
  test("a start refused for good (not retryable) is never sent again", { timeout: 30_000 }, () => {
    const { r, seen } = runRestarting("refused");
    expect(r.stdout).not.toContain("@@retry");
    expect(r.stdout).toContain("@@nostart");
    expect(r.status).toBe(1);
    expect(seen.filter((m) => m === "session/new")).toHaveLength(1);
  });
  // Run 45882763507 (own-host microVM, 2026-11-26): the socket refused the connection while acpmux restarted, and the
  // start gave up as @@nostart. A refused connect or a missing socket cannot have made a session; it is sent again.
  test("a socket that refuses while acpmux restarts is tried again and starts", { timeout: 30_000 }, () => {
    const { r, seen } = runRestarting("late");
    expect(r.stdout).toContain("@@retry ");
    expect(r.stdout).toContain("Connection refused");
    expect(r.stdout).toContain("@@session s-2");
    expect(r.status).toBe(0);
    expect(seen.filter((m) => m === "session/new")).toHaveLength(1);
  });
  test("a first prompt cut by acpmux's restart is sent again with the same promptId", { timeout: 30_000 }, () => {
    const { r, seen } = runRestarting("prompt-cut");
    expect(r.stdout).toContain("@@session s-2");
    expect(r.stdout).toContain("@@retry session/prompt");
    expect(r.stdout).toContain("@@prompted");
    expect(r.status).toBe(0);
    expect(seen.filter((m) => m === "session/new")).toHaveLength(1);
    const prompts = seen.filter((m) => m.startsWith("session/prompt:"));
    expect(prompts).toHaveLength(2);
    expect(prompts[0]).toBe(prompts[1]);
  });
  test("a start whose session was made before acpmux's restart cut its answer takes that session", { timeout: 30_000 }, () => {
    const { r, seen } = runRestarting("made-then-cut");
    expect(r.stdout).toContain("@@retry ");
    expect(r.stdout).toContain("@@adopted s-1");
    expect(r.stdout).toContain("@@session s-1");
    expect(r.status).toBe(0);
    expect(seen.filter((m) => m === "session/new")).toHaveLength(2);
    expect(seen.filter((m) => m === "_acpmux/resolve")).toHaveLength(1);
  });
  test("a taken name with no cut start before it stays a failed start", { timeout: 30_000 }, () => {
    const { r, seen } = runRestarting("taken");
    expect(r.stdout).toContain("@@nostart");
    expect(r.stdout).not.toContain("@@adopted");
    expect(r.status).toBe(1);
    expect(seen).not.toContain("_acpmux/resolve");
  });
  test("no acpmux socket is a failed start that names the paths it tried, after the retry window", { timeout: 30_000 }, () => {
    const home = mkdtempSync(join(tmpdir(), "journey-launch-"));
    try {
      const r = spawnSync("bash", ["-c", launchCredentialStartProgram("s", "claude", "CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-x")], { env: { PATH: process.env.PATH, HOME: home, CMUX_JOURNEY_START_RETRY_S: "3" }, encoding: "utf8" });
      expect(r.stdout).toContain("@@retry no acpmux socket at");
      expect(r.status).toBe(1);
      expect(r.stdout).toContain("@@nostart no acpmux socket at");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
  test("a red names which credential each model request carried", () => {
    const { createHash } = require("node:crypto") as typeof import("node:crypto");
    const sha = (s: string) => createHash("sha256").update(s).digest("hex");
    const want = sha("sk-ant-oat01-mine");
    const rows = [{ cred_sha256: sha(MODEL_PLANE_PLACEHOLDER) }, { cred_sha256: sha(MODEL_PLANE_PLACEHOLDER) }, { cred_sha256: want }, { cred_sha256: "" }, { cred_sha256: sha("other") }];
    const rowsShaped = rows.map((r, i) => ({ ...r, path: "/v1/messages", model: i === 0 ? "claude-haiku" : "stub-model", stream: i !== 0, tools: i === 0 ? [] : ["Bash"], step: 0 }));
    expect(credentialSeen(rowsShaped, want)).toBe("2 with the model-route placeholder, 1 with the login, 1 with no credential, 1 with another credential; not the login: /v1/messages model=claude-haiku stream=false tools=0 step=0; /v1/messages model=stub-model stream=true tools=1 step=0; /v1/messages model=stub-model stream=true tools=1 step=0; /v1/messages model=stub-model stream=true tools=1 step=0");
    expect(credentialSeen([{ cred_sha256: want }], want)).toBe("1 with the login");
  });
});

describe("the stub step's credential rule (cmux#40159)", () => {
  const { createHash } = require("node:crypto") as typeof import("node:crypto");
  const sha = (s: string) => createHash("sha256").update(s).digest("hex");
  const want = sha("sk-ant-oat01-mine");
  const turn = (cred: string, step = 0) => ({ cred_sha256: cred, tools: ["Bash", "Read"], step });
  // PR run 44092630546: three chat turns on the launch credential, and one title request (haiku, no tools) from
  // acpmux's own `claude -p`, on the machine's model route.
  const title = { cred_sha256: sha(MODEL_PLANE_PLACEHOLDER), tools: [], side: true, step: -1 };
  test("with the launch credential, chat turns must carry it and a title request may use the model route", () => {
    expect(judgeStubCredentials([turn(want), turn(want, 1), turn(want, 1), title], want, true)).toEqual({
      detail: "4 model requests: 3 chat turns, each with the launch credential (SHA-256 match); 1 side requests, 1 of them on the machine's model route",
    });
    expect(judgeStubCredentials([turn(want), turn(sha(MODEL_PLANE_PLACEHOLDER), 1)], want, true).error).toBe("a chat turn did not carry the login the journey passed");
    expect(judgeStubCredentials([turn(want), { ...title, cred_sha256: sha("someone-else") }], want, true).error).toBe("a side request carried neither the login nor the machine's model route");
    expect(judgeStubCredentials([title], want, true).error).toBe("no chat turn offered tools");
  });
  test("with a login on the machine, every request must carry it", () => {
    expect(judgeStubCredentials([turn(want), title], want, false).error).toBe("a model request did not carry the login the journey passed");
    expect(judgeStubCredentials([turn(want), { ...title, cred_sha256: want }], want, false)).toEqual({ detail: "2 model requests, each with the forwarded login (SHA-256 match)" });
  });
});

describe("the --surge proof (cmux-platform#1594)", () => {
  const slot = (index: number, machine_id: string | null, status = "created") => ({ index, status, machine_id, provider: "freestyle", reason: "r", retryable: false });
  const receipt = { ...SURGE_PROOF_REQUEST, slots: [slot(0, "vm_aaaaaaaaaaaaaaaaaaaa"), slot(1, "vm_bbbbbbbbbbbbbbbbbbbb")] };
  test("a replay matches only the same slots in the same order", () => {
    expect(sameSurgeSlots(receipt, structuredClone(receipt))).toBe(true);
    expect(sameSurgeSlots(receipt, { ...receipt, slots: [...receipt.slots].reverse() })).toBe(false);
    expect(sameSurgeSlots(receipt, { ...receipt, slots: [receipt.slots[0], slot(1, null, "queued")] })).toBe(false);
    expect(sameSurgeSlots(receipt, { ...receipt, slots: receipt.slots.slice(0, 1) })).toBe(false);
    expect(sameSurgeSlots(receipt, null)).toBe(false);
  });
  test("cleanup deletes each named machine once, across every receipt", () => {
    expect(surgeMachineIds(receipt, receipt, { slots: [slot(0, null, "refused")] }, undefined)).toEqual(["vm_aaaaaaaaaaaaaaaaaaaa", "vm_bbbbbbbbbbbbbbbbbbbb"]);
  });
  test("the proof asks for the smallest burst: 2 machines, 300 s", () => {
    expect(SURGE_PROOF_REQUEST).toEqual({ count: 2, ttl_seconds: 300 });
  });
});

describe("waitForSpareReady", () => {
  const api = {} as any;
  const never = (_a: unknown, _m: string, _b: number, signal?: AbortSignal) => new Promise<any>((_, reject) => signal?.addEventListener("abort", () => reject(new Error("aborted"))));
  test("an already-ready spare with no frame (production: no subscribe snapshot) is ready from its record", async () => {
    let reads = 0;
    const got = await waitForSpareReady(api, "vm_spare", 10_000, { frame: never as any, read: async () => (++reads < 2 ? { status: "starting" } : { status: "running", host: "h1", running_since: 5 }), pollMs: 1, sleep: async () => {} });
    expect(got.by).toBe("record");
    expect(got.frame).toBeNull();
    expect(got.row.running_since).toBe(5);
  });
  test("the frame wins when it comes first, and the record poll stops", async () => {
    let reads = 0;
    const frame = { event: "cloud.spare.ready", data: { machine: "vm_spare", at: 7 } };
    const got = await waitForSpareReady(api, "vm_spare", 10_000, { frame: (async () => frame) as any, read: async () => { reads++; return { status: "starting" }; }, pollMs: 1, sleep: () => new Promise((r) => setTimeout(r, 5)) });
    expect(got.by).toBe("frame");
    expect(got.frame).toBe(frame as any);
    const after = reads;
    await new Promise((r) => setTimeout(r, 30));
    expect(reads - after).toBeLessThanOrEqual(1);
  });
  test("a failed spare says so instead of waiting the budget", async () => {
    await expect(waitForSpareReady(api, "vm_spare", 10_000, { frame: never as any, read: async () => ({ status: "failed", error: "boom" }), pollMs: 1, sleep: async () => {} })).rejects.toThrow(/failed before ready/);
  });
  test("a spare the person's read cannot see (production: not_found under its reservation) is ready once its guest answers exec", async () => {
    const notFound = async () => { throw new Error('cloud.machine.get: HTTP 400 {"code":"cloud.machine.not_found"}'); };
    let probes = 0;
    const got = await waitForSpareReady(api, "vm_spare", 10_000, { frame: never as any, read: notFound, answers: async () => ++probes >= 2, pollMs: 1, sleep: async () => {} });
    expect(got.by).toBe("exec");
    expect(got.row.status).toBe("running");
    expect(probes).toBe(2);
  });
  test("an exec probe that fails keeps waiting, and another read error never probes", async () => {
    let probes = 0;
    await expect(waitForSpareReady(api, "vm_spare", 20, { frame: never as any, read: async () => { throw new Error("HTTP 503"); }, answers: async () => { probes++; return true; }, pollMs: 1, sleep: () => new Promise((r) => setTimeout(r, 2)) })).rejects.toThrow(/not ready within 20 ms/);
    expect(probes).toBe(0);
  });
  test("neither within the budget names both routes", async () => {
    await expect(waitForSpareReady(api, "vm_spare", 20, { frame: never as any, read: async () => ({ status: "starting" }), pollMs: 1, sleep: () => new Promise((r) => setTimeout(r, 2)) })).rejects.toThrow(/not ready within 20 ms/);
  });
});

describe("listedMachine (run 45174448964: `vm_... missing from 49 machines` on a shared account of 52)", () => {
  const rows = (a: number, b: number) => Array.from({ length: b - a }, (_, k) => ({ id: `vm_${a + k}`, status: "running" }));
  test("follows next_cursor to the page that holds the machine", async () => {
    const seen: unknown[] = [];
    const list = async (p: any) => { seen.push(p); return p.cursor ? { machines: rows(49, 52) } : { machines: rows(0, 49), next_cursor: "c2" }; };
    const r = await listedMachine("vm_51", list, async () => { throw new Error("not asked"); });
    expect(r.detail).toBe("52 machines");
    expect(seen).toEqual([{ limit: 100 }, { limit: 100, cursor: "c2" }]);
  });
  test("a capped page with no cursor: confirmed by cloud.machine.get, the cap named", async () => {
    const r = await listedMachine("vm_51", async () => ({ machines: rows(0, 49) }), async (id: string) => ({ id, status: "running", size: { cpu: 2 } }));
    expect(r.row.size).toEqual({ cpu: 2 });
    expect(r.detail).toContain("49 machines listed, no next_cursor (a page cap)");
  });
  test("a machine neither read finds fails", async () => {
    await expect(listedMachine("vm_99", async () => ({ machines: rows(0, 3) }), async () => { throw new Error("HTTP 404"); })).rejects.toThrow("vm_99 missing from 3 machines, and cloud.machine.get: HTTP 404");
    await expect(listedMachine("vm_99", async () => ({ machines: rows(0, 3) }), async () => ({ id: "vm_99", status: "deleted" }))).rejects.toThrow("reads deleted");
  });
});

describe("terminal scroll leg (carrier serve + __scroll-probe)", () => {
  const report = (o: Record<string, unknown> = {}) => JSON.stringify({
    surface: "cloud", bad: 1, seconds: 41.27, stream: { lines: 9000 },
    views: { mirror: { blank_rows: 0, missing_rows: 0, jumps: 1, bad: 1, samples: 80 }, daemon: { blank_rows: 0, missing_rows: 0, jumps: 0, bad: 0 } }, ...o,
  });

  test("keeps only the counts of both views and the seconds", () => {
    expect(parseScrollReport(`noise\n${report()}\n`)).toEqual({
      surface: "cloud", bad: 1, seconds: 41.3,
      views: { mirror: { blank_rows: 0, missing_rows: 0, jumps: 1 }, daemon: { blank_rows: 0, missing_rows: 0, jumps: 0 } },
    });
    expect(scrollDetail(parseScrollReport(report()))).toBe("bad 1 (mirror: 0 blank, 0 missing, 1 jumps; daemon: 0 blank, 0 missing, 0 jumps), 41.3 s");
  });

  test("the notes of a view that counted a defect go into the detail, never the counts", () => {
    const out = report({ bad: 1, views: {
      mirror: { blank_rows: 0, missing_rows: 0, jumps: 0, notes: ["mirror top moved by the probe"] },
      daemon: { blank_rows: 0, missing_rows: 0, jumps: 1, notes: ["daemon jump: top Some(812) -> Some(840) (offset 37)"] },
    } });
    const notes = scrollNotes(out);
    expect(notes).toEqual(["daemon: daemon jump: top Some(812) -> Some(840) (offset 37)"]);
    expect(parseScrollReport(out)).not.toHaveProperty("notes");
    expect(scrollDetail(parseScrollReport(out), notes)).toBe("bad 1 (mirror: 0 blank, 0 missing, 0 jumps; daemon: 0 blank, 0 missing, 1 jumps), 41.3 s; notes: daemon: daemon jump: top Some(812) -> Some(840) (offset 37)");
    expect(scrollNotes("not json")).toEqual([]);
    expect(scrollNotes(report())).toEqual([]);
  });

  test("a report that is not whole is refused, never read as 0", () => {
    expect(() => parseScrollReport("")).toThrow("not a JSON report");
    expect(() => parseScrollReport(report({ views: { mirror: { blank_rows: 0, missing_rows: 0, jumps: 0 } } }))).toThrow("daemon view");
    expect(() => parseScrollReport(report({ bad: 0 }))).toThrow("bad is not the sum");
    expect(() => parseScrollReport(report({ views: { mirror: { blank_rows: -1, missing_rows: 0, jumps: 0 }, daemon: { blank_rows: 0, missing_rows: 0, jumps: 0 } } }))).toThrow("mirror view");
  });

  // One stand-in for both verbs: `carrier serve` writes its ready line and waits for stdin to end; `__scroll-probe`
  // records its arguments and prints PROBE_OUT.
  const fake = (probe: string, serve = `echo '{"ok":true,"socket":"'"$6"'","route":"carrier"}' >&2; cat >/dev/null; echo served-out > "$D/serve-ended"`) => {
    const dir = mkdtempSync(join(tmpdir(), "journey-scroll-"));
    const bin = join(dir, "cmux");
    writeFileSync(bin, `#!/bin/bash\nD="${dir}"\nif [ "$1" = carrier ]; then printf '%s\\n' "$*" > "$D/serve-args"; printf '%s\\n' "$CMUX_CLOUD_API_URL $CMUX_CLOUD_ACCESS_TOKEN" > "$D/serve-env"; ${serve}; exit 0; fi\nprintf '%s\\n' "$*" > "$D/probe-args"\n${probe}\n`, { mode: 0o755 });
    return { dir, bin };
  };
  const api = { origin: "https://api.example", bearer: "session-value", team: "team_0123456789abcdef0123" };

  test("serves the machine on a private socket and runs the probe against it as the cloud surface", async () => {
    const { dir, bin } = fake(`echo '${report()}'`);
    const t = await carrierScrollProbe(bin, api, "vm_abcdefghij0123456789", 5);
    expect(t.bad).toBe(1);
    const serveArgs = readFileSync(join(dir, "serve-args"), "utf8").trim().split(" ");
    expect(serveArgs.slice(0, 5)).toEqual(["carrier", "serve", "--machine", "vm_abcdefghij0123456789", "--socket"]);
    expect(serveArgs.slice(6)).toEqual(["--team", "team_0123456789abcdef0123"]);
    const socket = serveArgs[5];
    expect(readFileSync(join(dir, "serve-env"), "utf8").trim()).toBe("https://api.example session-value");
    expect(readFileSync(join(dir, "probe-args"), "utf8").trim()).toBe(`__scroll-probe --socket ${socket} --surface-label cloud --json --timeout-seconds 5`);
    // The state dir (and the socket in it) goes with the step.
    expect(existsSync(dirname(socket))).toBe(false);
    rmSync(dir, { recursive: true, force: true });
  });

  test("a serve that refuses before its ready line is the step's reason, and no probe runs", async () => {
    const { dir, bin } = fake(`echo '${report()}'`, `echo '{"ok":false,"error_code":"device_key","route":"carrier"}' >&2; exit 5`);
    await expect(carrierScrollProbe(bin, api, "vm_abcdefghij0123456789", 5)).rejects.toThrow('carrier serve: {"ok":false,"error_code":"device_key"');
    expect(existsSync(join(dir, "probe-args"))).toBe(false);
    rmSync(dir, { recursive: true, force: true });
  });

  test("a probe that fails names its stderr and the serve's connection lines", async () => {
    const { dir, bin } = fake(`sleep 0.3; echo 'scroll-probe: identify: no answer' >&2; exit 1`,
      `echo '{"ok":true,"socket":"x","route":"carrier"}' >&2; echo '{"ok":false,"error_code":"relay","route":"carrier"}' >&2; cat >/dev/null`);
    await expect(carrierScrollProbe(bin, api, "vm_abcdefghij0123456789", 5)).rejects.toThrow(/exit 1: scroll-probe: identify: no answer; carrier serve: .*relay/);
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("guestTimed", () => {
  const { guestTimed, guestMs, guestDetail } = require("./cloud-journey");
  test("times a heredoc command on its own lines and keeps its output and exit marker", () => {
    const r = spawnSync("bash", ["-c", guestTimed(`python3 -I - <<'X'\nprint('@@session s1')\nX\necho "@@exit $?"`)], { encoding: "utf8" });
    expect(r.stdout).toContain("@@session s1");
    expect(r.stdout).toContain("@@exit 0");
    const ms = guestMs(r.stdout);
    expect(ms).not.toBeNull();
    expect(ms).toBeGreaterThanOrEqual(0);
    expect(guestDetail(ms)).toContain("on the guest");
    expect(guestDetail(null)).toBe("");
  });
});

describe("send trace after the first token", () => {
  test("waits ~5 s after the first token, saves send-trace.json, and a 404 only prints", async () => {
    const dir = mkdtempSync(join(tmpdir(), "journey-send-trace-"));
    try {
      const waited: number[] = [];
      const events = [{ name: "api", ph: "X", ts: 1, dur: 45_000, args: { trace_id: "a", hop: "api", floor_ms: 30 } }];
      const ok = await saveSendTrace({ raw: async () => ({ status: 200, body: events, text: "" }) as any }, "a".repeat(32), 1_000, dir, () => 2_000, async (ms) => { waited.push(ms); });
      expect(ok).toBe(true);
      expect(waited).toEqual([SEND_TRACE_SETTLE_MS - 1_000]);
      expect(JSON.parse(readFileSync(join(dir, "send-trace.json"), "utf8"))).toEqual(events);
      const gone = await saveSendTrace({ raw: async () => ({ status: 404, body: {}, text: "" }) as any }, "b".repeat(32), null, dir, () => 0, async () => {});
      expect(gone).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("requestTimedOut", () => {
  test("is a client timeout, so a keyed op is asked again under its key", () => {
    expect(requestTimedOut(new DOMException("The operation timed out.", "TimeoutError"))).toBe(true);
    expect(requestTimedOut(new Error("The operation timed out."))).toBe(true);
    expect(requestTimedOut(new Error("wrapped", { cause: new DOMException("x", "TimeoutError") }))).toBe(true);
  });
  test("is not any other failure", () => {
    expect(requestTimedOut(new DOMException("aborted", "AbortError"))).toBe(false);
    expect(requestTimedOut(Object.assign(new Error("reset"), { code: "ECONNRESET" }))).toBe(false);
    expect(requestTimedOut(undefined)).toBe(false);
  });
});

describe("a machine create with one overall deadline (run 45874526877: cold create waited 847 s)", () => {
  /** A local API that records each request's bearer, and answers a create only after `holdMs`. */
  async function api<T>(holdMs: number, run: (url: string, bearers: string[], creates: () => number) => Promise<T>): Promise<T> {
    const bearers: string[] = [];
    let creates = 0;
    const server = Bun.serve({ port: 0, hostname: "127.0.0.1", async fetch(req) {
      bearers.push(req.headers.get("authorization") ?? "");
      const body: any = await req.json().catch(() => ({}));
      if (body?.op === "cloud.machine.create") { creates++; await Bun.sleep(holdMs); }
      return Response.json({ ok: true, value: { host: "h" } });
    } });
    try { return await run(`http://127.0.0.1:${server.port}`, bearers, () => creates); } finally { server.stop(true); }
  }

  test("an op with a deadline is not sent again past it (the cold create's 2 x 300 s, run 45874526877)", async () => {
    await api(3_000, async (url, _b, creates) => {
      const a = new Api(url);
      const t0 = Date.now();
      await expect(a.op("cloud.machine.create", {}, "k", {}, 1_000, Date.now() + 1_500)).rejects.toThrow("no answer within its bound");
      expect(Date.now() - t0).toBeLessThan(2_500);
      expect(creates()).toBeLessThanOrEqual(2);
    });
  });
});

describe("rpcFailureReason", () => {
  test("a 503 vm_unavailable says which Durable Object failure it was, and only the three fixed words", () => {
    expect(rpcFailureReason("restarted")).toBe(" (restarted)");
    expect(rpcFailureReason("overloaded")).toBe(" (overloaded)");
    expect(rpcFailureReason("unreachable")).toBe(" (unreachable)");
    expect(rpcFailureReason("Error: secret text")).toBe("");
    expect(rpcFailureReason(undefined)).toBe("");
  });
});


describe("wake-echo own-run cleanup", () => {
  const scope = { repository: "manaflow-ai/cmux", run: "123", attempt: "2", job: "wake-echo", api: "https://staging.example", team: "" };
  const machine = "vm_11111111111111111111";
  const key = "jr-test123-cleanup-delete";
  const withFile = async (run: (file: string) => Promise<void>) => {
    const dir = mkdtempSync(join(tmpdir(), "wake-cleanup-test-"));
    try { await run(join(dir, "created.json")); } finally { rmSync(dir, { recursive: true, force: true }); }
  };

  test("a fresh process recovers the returned ID and original delete key after the journey is killed", async () => withFile(async (file) => {
    const child = spawnSync(process.execPath, ["-e", `
      import { writeWakeCleanup } from ${JSON.stringify(new URL("./cloud-journey.ts", import.meta.url).pathname)};
      writeWakeCleanup(${JSON.stringify(file)}, ${JSON.stringify(scope)}, ${JSON.stringify(machine)}, ${JSON.stringify(key)});
      process.kill(process.pid, "SIGKILL");
    `]);
    expect(child.signal).toBe("SIGKILL");
    const calls: string[][] = [];
    const record = journey.readWakeCleanup(file, scope);
    expect(record).toMatchObject({ version: 1, machine, key, scope });
    let deleted = false;
    await journey.cleanupWakeMachine(record, {
      get: async (id: string) => { calls.push(["get", id]); return { status: deleted ? "deleting" : "paused" }; },
      remove: async (id: string, k: string) => { calls.push(["delete", id, k]); deleted = true; },
    });
    expect(calls).toEqual([["get", machine], ["delete", machine, key], ["get", machine]]);
    expect(readFileSync(file, "utf8")).not.toContain("token");
  }));

  test("missing record and already deleted machine need no delete", async () => withFile(async (file) => {
    expect(journey.readWakeCleanup(file, scope)).toBeNull();
    journey.writeWakeCleanup(file, scope, machine, key);
    for (const row of [null, { status: "deleted" }, { status: "deleting" }]) {
      await journey.cleanupWakeMachine(journey.readWakeCleanup(file, scope), {
        get: async () => row, remove: async () => { throw new Error("unexpected delete"); },
      });
    }
  }));

  test("another run, attempt, job, backend or team cannot consume the record", async () => withFile(async (file) => {
    journey.writeWakeCleanup(file, scope, machine, key);
    for (const field of Object.keys(scope)) {
      expect(() => journey.readWakeCleanup(file, { ...scope, [field]: "different" })).toThrow(/scope/);
    }
    const record = JSON.parse(readFileSync(file, "utf8"));
    for (const bad of [{ ...record, version: 2 }, { ...record, machine: "" }, { ...record, key: "" }]) {
      writeFileSync(file, JSON.stringify(bad));
      expect(() => journey.readWakeCleanup(file, scope)).toThrow(/record/);
    }
  }));

  test("read errors never trigger deletion and an unconfirmed delete fails", async () => withFile(async (file) => {
    journey.writeWakeCleanup(file, scope, machine, key);
    const record = journey.readWakeCleanup(file, scope);
    await expect(journey.cleanupWakeMachine(record, {
      get: async () => { throw new Error("HTTP 403"); },
      remove: async () => { throw new Error("unexpected delete"); },
    })).rejects.toThrow("HTTP 403");
    await expect(journey.cleanupWakeMachine(record, {
      get: async () => ({ status: "paused" }), remove: async () => {},
    })).rejects.toThrow(/not confirmed/);
  }));

  test("a lost delete reply is settled by readback without hiding a live machine or another error", async () => withFile(async (file) => {
    journey.writeWakeCleanup(file, scope, machine, key);
    const record = journey.readWakeCleanup(file, scope);
    for (const status of ["deleted", "deleting"]) {
      let called = false;
      await journey.cleanupWakeMachine(record, {
        get: async () => ({ status: called ? status : "paused" }),
        remove: async () => { called = true; throw new Error("TimeoutError"); },
      });
    }
    await expect(journey.cleanupWakeMachine(record, {
      get: async () => ({ status: "paused" }), remove: async () => { throw new Error("mutation.indeterminate"); },
    })).rejects.toThrow("mutation.indeterminate");
  }));

  test("workflow cleans its record on failure or cancellation before artifact upload", () => {
    const workflow = readFileSync(new URL("../../.github/workflows/cloud-wake-echo.yml", import.meta.url), "utf8");
    const cleanup = workflow.indexOf("- name: Delete this run's machine");
    expect(cleanup).toBeGreaterThan(workflow.indexOf("--wake-echo 50"));
    const step = workflow.slice(cleanup, workflow.indexOf("uses: actions/upload-artifact", cleanup));
    expect(step).toContain("if: always()");
    expect(step).toContain("timeout-minutes: 6");
    expect(step).toContain('--cleanup-wake-record "$out/created-machine.json"');
    expect(workflow).toContain('--wake-cleanup-record "$out/created-machine.json"');
    expect(workflow).toContain("wake-echo-${{ github.run_id }}-${{ github.run_attempt }}");
  });
});
