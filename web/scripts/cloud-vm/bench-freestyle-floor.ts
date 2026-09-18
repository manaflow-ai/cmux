#!/usr/bin/env bun
/**
 * Provider floor benchmark for cmux Cloud machines (issue #12905): what
 * Freestyle itself costs, measured with the SDK and no cmux control plane.
 *
 *   FREESTYLE_API_KEY=… bun scripts/cloud-vm/bench-freestyle-floor.ts [--trials N] [--size md] [--image sh-…] [--burst K] [--no-vpc] [--out <file.json>]
 *
 * Per trial, from the manifest's default snapshot for the size: allocation
 * (`vms.create` returning), first successful guest exec, the baked daemon
 * process running and listening on 1337, the strict private-network
 * announcement exec, exec/data/fs round trips, guest shell startup as the
 * work user (login non-interactive, and interactive under a pty with ble.sh),
 * pause, start, daemon-after-resume and delete. `--burst K` adds K concurrent
 * creates to expose allocation contention. Readiness milestones come from a
 * 250 ms poll, so each is late by up to one interval plus the probe round
 * trip; the interval is reported in the summary. Every VM and the benchmark
 * VPC are deleted before exit, including on failure; existing machines are
 * never read.
 */
import { Freestyle, FreestyleApiError, type Vm } from "freestyle";
import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import { shellQuote } from "../../services/vms/drivers/cmuxTuiDaemon";
import { FREESTYLE_NETWORK_FIREWALL_RULES, freestyleFirewallRules } from "../../services/vms/drivers/freestyle";
import { freestyleNetworkAnnouncementCommand } from "../../services/vms/drivers/freestyleNetworkAnnouncement";
import { resolveVmImage } from "../../services/vms/images/resolver";
import { isVmImageSizeName, vmImageSize } from "../../services/vms/images/sizes";
import { elapsedMs, formatSummary, summarize, summarizeFields } from "./benchStats.mjs";

type Probe = { ms: number; execOk: boolean; listening: boolean; running: boolean };
type DaemonMilestones = { firstExecMs: number | null; daemonProcessMs: number | null; daemonListenMs: number | null; probeAttempts: number };
type Trial = Record<string, unknown> & { index: number };

const args = process.argv.slice(2);
const option = (flag: string): string | undefined => {
  const at = args.indexOf(flag);
  return at === -1 ? undefined : args[at + 1];
};
const trials = Number(option("--trials") ?? "3");
const burst = Number(option("--burst") ?? "0");
const sizeName = option("--size") ?? "md";
const withVpc = !args.includes("--no-vpc");
const outPath = option("--out");
if (!Number.isInteger(trials) || trials < 0 || !Number.isInteger(burst) || burst < 0 || !isVmImageSizeName(sizeName)) {
  console.error("bench-freestyle-floor: --trials and --burst take non-negative integers; --size is sm|md|lg|lgx|xl|2xl");
  process.exit(2);
}
if (trials === 0 && burst === 0) {
  console.error("bench-freestyle-floor: nothing to measure (--trials 0 and --burst 0)");
  process.exit(2);
}
if (!process.env.FREESTYLE_API_KEY) {
  console.error("Set FREESTYLE_API_KEY (source ~/.secrets/cmux.env)");
  process.exit(2);
}
const size = vmImageSize(sizeName);
const image = option("--image") ?? resolveVmImage("freestyle", undefined, process.env, { kind: "desktop", memoryMb: size.memoryMb }).image;
const fs = new Freestyle({ apiKey: process.env.FREESTYLE_API_KEY });
const runId = `bench-${randomUUID().slice(0, 8)}`;
const PROBE_INTERVAL_MS = 250;
// Fail closed: a resource the run could not delete, or an interrupted run, is
// a failed benchmark (exit 1 and `ok: false`), never a clean exit.
const cleanupFailures: string[] = [];
let interrupted = false;
const interrupt = () => { interrupted = true; };
process.once("SIGINT", interrupt);
process.once("SIGTERM", interrupt);
function checkInterrupted(): void {
  if (interrupted) throw new Error("interrupted");
}
// `[s]tart` keeps pgrep from matching this probe's own shell.
const PROBE_COMMAND = "l=0; grep -qi ':0539 ' /proc/net/tcp6 2>/dev/null && l=1; r=0; pgrep -f 'cmux-tui server [s]tart' >/dev/null 2>&1 && r=1; echo \"$l $r\"";
const WORK_USER_ENV = "setpriv --reuid=cmux --regid=cmux --init-groups env HOME=/home/cmux USER=cmux LOGNAME=cmux SHELL=/bin/bash TERM=xterm-256color TERM_PROGRAM=ghostty";
// Each wrapper prints the elapsed milliseconds and then exits with the
// measured command's own status, so a shell that failed or was killed by
// `timeout` is a failed sample, not a fast one.
const LOGIN_SHELL_MS = "s=$(date +%s%N); bash -lc true; rc=$?; e=$(date +%s%N); echo $(((e-s)/1000000)); exit $rc";
const INTERACTIVE_PTY_MS = "s=$(date +%s%N); printf 'exit\\n' | timeout 25 script -q -e -c 'bash -il' /dev/null >/dev/null 2>&1; rc=$?; e=$(date +%s%N); echo $(((e-s)/1000000)); exit $rc";

async function timed<T>(run: () => Promise<T>): Promise<{ ms: number; value: T }> {
  const startedAt = performance.now();
  const value = await run();
  return { ms: elapsedMs(startedAt), value };
}

async function exec(vm: Vm, command: string, timeoutMs = 10_000): Promise<{ ms: number; exitCode: number | null; stdout: string }> {
  const { ms, value } = await timed(() => vm.exec({ command, timeoutMs, linuxUser: "root" }));
  return { ms, exitCode: value.statusCode ?? null, stdout: (value.stdout ?? "").trim() };
}

/** A required guest command: a non-zero exit fails the trial instead of becoming a sample. */
async function execOk(vm: Vm, command: string, label: string, timeoutMs = 10_000) {
  const result = await exec(vm, command, timeoutMs);
  if (result.exitCode !== 0) throw new Error(`${label} exited ${result.exitCode ?? "timeout"}`);
  return result;
}

async function probe(vm: Vm): Promise<Probe> {
  try {
    const result = await exec(vm, PROBE_COMMAND, 3_000);
    const [listening, running] = result.stdout.split(" ");
    return { ms: result.ms, execOk: result.exitCode === 0, listening: listening === "1", running: running === "1" };
  } catch {
    return { ms: 0, execOk: false, listening: false, running: false };
  }
}

/** Polls the guest until the daemon process runs and listens on 1337; returns milestone offsets from `origin`. */
async function waitForDaemon(vm: Vm, origin: number, budgetMs = 90_000): Promise<DaemonMilestones> {
  const milestones: DaemonMilestones = { firstExecMs: null, daemonProcessMs: null, daemonListenMs: null, probeAttempts: 0 };
  while (performance.now() - origin < budgetMs) {
    milestones.probeAttempts += 1;
    const result = await probe(vm);
    const at = elapsedMs(origin);
    if (result.execOk && milestones.firstExecMs === null) milestones.firstExecMs = at;
    if (result.running && milestones.daemonProcessMs === null) milestones.daemonProcessMs = at;
    if (result.listening && milestones.daemonListenMs === null) milestones.daemonListenMs = at;
    if (milestones.daemonListenMs !== null) break;
    checkInterrupted();
    await new Promise((resolve) => setTimeout(resolve, PROBE_INTERVAL_MS));
  }
  return milestones;
}

/**
 * Deletes every machine this run created, including one whose create
 * response never arrived (the SDK rejected while the platform allocated), by
 * listing on the run id the create wrote into metadata.
 */
async function reconcileRunVms(): Promise<void> {
  try {
    const listed = await fs.vms.list({ metadata: `cmux:bench,run:${runId}`, limit: 200 });
    for (const data of listed.vms) {
      console.error(`cleanup_reconcile_vm=${data.id}`);
      await deleteVm(fs.vms.ref(data.id), data.id);
    }
  } catch (error) {
    cleanupFailures.push(`list run machines: ${error instanceof Error ? error.message : String(error)}`);
  }
}

/** A VM delete releases its VPC addresses asynchronously; the VPC delete answers 409 until then. */
async function deleteVpcWithRetry(id: string): Promise<void> {
  for (let attempt = 0; attempt < 12; attempt += 1) {
    try {
      await fs.vpc.delete(id);
      return;
    } catch (error) {
      if (!(error instanceof FreestyleApiError && error.status === 409) || attempt === 11) throw error;
      await new Promise((resolve) => setTimeout(resolve, 2_500));
    }
  }
}

async function createVm(vpcId: string | null, name: string) {
  const { ms, value } = await timed(() => fs.vms.create({
    snapshotId: image,
    displayName: name,
    idleTimeoutSeconds: -1,
    // The run id in metadata is what exit-time reconciliation lists by, so a
    // create whose response was lost still gets its machine deleted.
    metadata: { cmux: "bench", run: runId },
    // Egress only, with or without a VPC: the baked daemon grants every link
    // on its listener (trusted carrier), so it must never face the Internet,
    // and this benchmark only ever reaches the guest through the exec API.
    firewall: { rules: freestyleFirewallRules() },
    ...(vpcId ? { vpcs: [{ vpcId, ipv4: true, ipv6: true }] } : {}),
  }));
  return { allocMs: ms, vm: value.vm, vmId: value.vmId, data: value.data };
}

async function repeat(count: number, run: () => Promise<number>): Promise<ReturnType<typeof summarize>> {
  const samples: number[] = [];
  for (let index = 0; index < count; index += 1) samples.push(await run());
  return summarize(samples);
}

async function guestShellMs(vm: Vm, script: string, label: string): Promise<number> {
  const result = await execOk(vm, `${WORK_USER_ENV} sh -c ${shellQuote(script)}`, label, 60_000);
  const value = Number(result.stdout.split("\n").pop());
  if (!Number.isFinite(value)) throw new Error(`${label} printed no duration`);
  return value;
}

/** Deletes one benchmark VM; a failure is recorded as a cleanup failure, never swallowed. */
async function deleteVm(vm: Vm, vmId: string): Promise<number | null> {
  const startedAt = performance.now();
  try {
    await vm.delete();
    return elapsedMs(startedAt);
  } catch (error) {
    cleanupFailures.push(`VM ${vmId}: ${error instanceof Error ? error.message : String(error)}`);
    console.error(`cleanup_needed_vm=${vmId}`);
    return null;
  }
}

async function runTrial(index: number, vpcId: string | null): Promise<Trial> {
  const trial: Trial = { index, image, size: size.name, startedAt: new Date().toISOString() };
  const origin = performance.now();
  const created = await createVm(vpcId, `${runId}-${index}`);
  const { vm, vmId } = created;
  trial.vmId = vmId;
  trial.allocMs = created.allocMs;
  trial.stateAtCreate = created.data.state;
  try {
    const boot = await waitForDaemon(vm, origin);
    Object.assign(trial, boot);
    if (boot.daemonListenMs === null) throw new Error(`daemon not listening within budget (first exec ${boot.firstExecMs ?? "never"} ms)`);
    checkInterrupted();
    const addresses = (created.data.vpcs ?? []).flatMap((network) => [network.ipv4, network.ipv6]).filter((value): value is string => typeof value === "string" && value.length > 0);
    if (addresses.length > 0) {
      trial.announceMs = (await execOk(vm, freestyleNetworkAnnouncementCommand(addresses), "announce", 5_000)).ms;
    }
    trial.execRtt = await repeat(10, async () => (await execOk(vm, "true", "exec true")).ms);
    trial.dataRtt = await repeat(3, async () => (await timed(() => vm.data())).ms);
    const payload = "#!/bin/sh\n".padEnd(20_480, "#");
    trial.fsWriteRtt = await repeat(3, async () => (await timed(() => vm.fs.writeTextFile(`/tmp/${runId}-shim`, payload, { mode: 0o755 }))).ms);
    trial.loginShellGuestMs = await repeat(3, () => guestShellMs(vm, LOGIN_SHELL_MS, "login shell"));
    trial.interactivePtyGuestMs = await repeat(3, () => guestShellMs(vm, INTERACTIVE_PTY_MS, "interactive shell"));
    checkInterrupted();
    const paused = await timed(() => vm.pause());
    trial.pauseMs = paused.ms;
    trial.stateAfterPause = paused.value.state;
    if (paused.value.state !== "paused" && paused.value.state !== "pausing") throw new Error(`pause left the VM ${paused.value.state}`);
    const resumeOrigin = performance.now();
    const started = await timed(() => vm.start());
    trial.startMs = started.ms;
    trial.stateAfterStart = started.value.state;
    const afterResume = await waitForDaemon(vm, resumeOrigin, 60_000);
    trial.resumeFirstExecMs = afterResume.firstExecMs;
    trial.resumeDaemonListenMs = afterResume.daemonListenMs;
    if (afterResume.daemonListenMs === null) throw new Error("daemon not listening after resume");
  } finally {
    trial.deleteMs = await deleteVm(vm, vmId);
  }
  return trial;
}

async function runBurst(vpcId: string | null): Promise<Trial[]> {
  const origin = performance.now();
  return Promise.all(Array.from({ length: burst }, async (_, index): Promise<Trial> => {
    const trial: Trial = { index, burst: true };
    try {
      const created = await createVm(vpcId, `${runId}-burst-${index}`);
      trial.vmId = created.vmId;
      trial.allocMs = created.allocMs;
      trial.allocDoneAtMs = elapsedMs(origin);
      try {
        const boot = await waitForDaemon(created.vm, origin);
        Object.assign(trial, boot);
        if (boot.daemonListenMs === null) throw new Error("daemon not listening within budget");
      } finally {
        await deleteVm(created.vm, created.vmId);
      }
    } catch (error) {
      trial.error = error instanceof Error ? error.message : String(error);
    }
    return trial;
  }));
}

let vpcId: string | null = null;
const results: { sequential: Trial[]; burst: Trial[] } = { sequential: [], burst: [] };
try {
  if (withVpc) {
    const created = await timed(() => fs.vpc.create({ slug: runId, displayName: runId, firewall: { rules: FREESTYLE_NETWORK_FIREWALL_RULES } }));
    vpcId = created.value.data.id;
    console.error(`vpc ${vpcId} created in ${created.ms} ms`);
  }
  for (let index = 0; index < trials && !interrupted; index += 1) {
    try {
      results.sequential.push(await runTrial(index, vpcId));
      console.error(`trial ${index}: ${JSON.stringify(results.sequential.at(-1))}`);
    } catch (error) {
      results.sequential.push({ index, error: error instanceof Error ? error.message : String(error) });
      console.error(`trial ${index} failed: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  if (burst > 0 && !interrupted) {
    results.burst = await runBurst(vpcId);
    console.error(`burst: ${JSON.stringify(results.burst)}`);
  }
} finally {
  await reconcileRunVms();
  if (vpcId) {
    await deleteVpcWithRetry(vpcId).catch((error: unknown) => {
      cleanupFailures.push(`VPC ${vpcId}: ${error instanceof Error ? error.message : String(error)}`);
      console.error(`cleanup_needed_vpc=${vpcId}`);
    });
  }
  process.off("SIGINT", interrupt);
  process.off("SIGTERM", interrupt);
}
const ok = results.sequential.filter((trial) => !trial.error);
const summary = {
  ok: !interrupted && cleanupFailures.length === 0 && ok.length === results.sequential.length && results.burst.every((trial) => !trial.error),
  interrupted,
  cleanupFailures,
  probeIntervalMs: PROBE_INTERVAL_MS,
  image,
  size: size.name,
  vpc: withVpc,
  trials,
  burst,
  sequential: summarizeFields(ok, ["allocMs", "firstExecMs", "daemonProcessMs", "daemonListenMs", "announceMs", "pauseMs", "startMs", "resumeFirstExecMs", "resumeDaemonListenMs", "deleteMs"]),
  guest: {
    execRtt: summarize(ok.flatMap((trial) => [(trial.execRtt as { p50?: number })?.p50 ?? Number.NaN])),
    loginShellGuestMs: summarize(ok.map((trial) => (trial.loginShellGuestMs as { p50?: number })?.p50 ?? Number.NaN)),
    interactivePtyGuestMs: summarize(ok.map((trial) => (trial.interactivePtyGuestMs as { p50?: number })?.p50 ?? Number.NaN)),
  },
  burstSummary: summarizeFields(results.burst.filter((trial) => !trial.error), ["allocMs", "allocDoneAtMs", "daemonProcessMs", "daemonListenMs"]),
  results,
};
console.error(formatSummary({ ...summary.sequential, ...summary.guest, ...Object.fromEntries(Object.entries(summary.burstSummary).map(([name, value]) => [`burst:${name}`, value])) }));
const text = JSON.stringify(summary);
if (outPath) writeFileSync(outPath, `${text}\n`);
console.log(text);
if (!summary.ok) process.exitCode = 1;
