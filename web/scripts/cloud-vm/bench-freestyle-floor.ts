#!/usr/bin/env bun
/**
 * Provider floor benchmark for cmux Cloud machines (issue #12905): what
 * Freestyle itself costs, measured with the SDK and no cmux control plane.
 *
 *   FREESTYLE_API_KEY=… bun scripts/cloud-vm/bench-freestyle-floor.ts [--trials N] [--size md] [--image sh-…] [--burst K] [--no-vpc] [--out <file.json>]
 *
 * The provider credential is read the way the runtime's client reads it:
 * FREESTYLE_API_KEY, or FREESTYLE_STACK_ACCESS_TOKEN with FREESTYLE_TEAM_ID
 * (source ~/.secrets/cmux.env).
 *
 * Per trial, from the manifest's default snapshot for the size: allocation
 * (`vms.create` returning), first successful guest exec, the baked daemon
 * process running and, bound to this machine's instance id, listening on
 * 1337 (the image's own health predicate, so a clone's stale daemon never
 * counts as ready), the strict private-network
 * announcement exec, exec/data/fs round trips, guest shell startup as the
 * work user (login non-interactive, and interactive under a pty with ble.sh),
 * pause, start, daemon-after-resume and delete. `--burst K` adds K concurrent
 * creates to expose allocation contention. Readiness milestones come from a
 * 250 ms poll, so each is late by up to one interval plus the probe round
 * trip; the interval is reported in the summary. Every VM and the benchmark
 * VPC are deleted before exit, including on failure; existing machines are
 * never read.
 */
import { type Freestyle, FreestyleApiError, type Vm } from "freestyle";
import { randomUUID } from "node:crypto";
import { writeFileSync, writeSync } from "node:fs";
import { shellQuote } from "../../services/vms/drivers/cmuxTuiDaemon";
import { FREESTYLE_NETWORK_FIREWALL_RULES, freestyleClient, freestyleFirewallRules } from "../../services/vms/drivers/freestyle";
import { freestyleNetworkAnnouncementCommand } from "../../services/vms/drivers/freestyleNetworkAnnouncement";
import { resolveVmImage } from "../../services/vms/images/resolver";
import { isVmImageSizeName, vmImageSize } from "../../services/vms/images/sizes";
import { elapsedMs, formatSummary, summarize, summarizeFields } from "./benchStats.mjs";

type Probe = { ms: number; execOk: boolean; listening: boolean; running: boolean; healthy: boolean; instanceId: string | null };
type DaemonMilestones = { firstExecMs: number | null; daemonProcessMs: number | null; daemonListenMs: number | null; probeAttempts: number; instanceId: string | null };
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
const size = vmImageSize(sizeName);
const image = option("--image") ?? resolveVmImage("freestyle", undefined, process.env, { kind: "desktop", memoryMb: size.memoryMb }).image;
// The runtime's own credential resolution (API key, or Stack access token
// with a team id). Each fetch is bounded well above the longest guest exec;
// the SDK backgrounds long requests anyway, and every await is raced by
// `bounded`.
const fs = providerClientOrExit();
function providerClientOrExit(): Freestyle {
  try {
    return freestyleClient(180_000);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(2);
  }
}
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
// The machine's own instance id from the platform's metadata service, the
// same token dance the image's health predicate uses.
const INSTANCE_ID_COMMAND = "curl -sf -m 2 -H \"X-aws-ec2-metadata-token: $(curl -sf -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-metadata-token-ttl-seconds: 60')\" http://169.254.169.254/latest/meta-data/instance-id";

/**
 * The readiness probe, the image's own health predicate split into fields:
 * the daemon process runs (`[s]tart` keeps pgrep from matching the probe's
 * own shell), something listens on 1337, and the daemon is the one bound to
 * this machine. An image that binds identity ships /etc/cmux/bake-instance-id
 * and its supervisor writes the bound id to /etc/cmux/daemon-instance-id; a
 * clone briefly runs the source machine's daemon until the supervisor
 * re-keys it, and that stale listener must not count as ready. The instance
 * id is read from the metadata service until it is known, then passed back
 * in, so a probe costs one exec and no metadata round trips.
 */
function probeCommand(instanceId: string | null): string {
  const id = instanceId === null ? `i=$(${INSTANCE_ID_COMMAND})` : `i=${shellQuote(instanceId)}`;
  return `${id}; l=0; grep -qi ':0539 ' /proc/net/tcp6 2>/dev/null && l=1; r=0; pgrep -f 'cmux-tui server [s]tart' >/dev/null 2>&1 && r=1; v=0; { [ ! -f /etc/cmux/bake-instance-id ] || { [ -n "$i" ] && [ "$(cat /etc/cmux/daemon-instance-id 2>/dev/null)" = "$i" ]; }; } && v=1; echo "$l $r $v $i"`;
}
const WORK_USER_ENV = "setpriv --reuid=cmux --regid=cmux --init-groups env HOME=/home/cmux USER=cmux LOGNAME=cmux SHELL=/bin/bash TERM=xterm-256color TERM_PROGRAM=ghostty";
// Each wrapper prints the elapsed milliseconds and then exits with the
// measured command's own status, so a shell that failed or was killed by
// `timeout` is a failed sample, not a fast one.
const LOGIN_SHELL_MS = "s=$(date +%s%N); bash -lc true; rc=$?; e=$(date +%s%N); echo $(((e-s)/1000000)); exit $rc";
const INTERACTIVE_PTY_MS = "s=$(date +%s%N); printf 'exit\\n' | timeout 25 script -q -e -c 'bash -il' /dev/null >/dev/null 2>&1; rc=$?; e=$(date +%s%N); echo $(((e-s)/1000000)); exit $rc";

/**
 * The SDK can keep polling a backgrounded request while the platform answers
 * 202, so every provider await is raced against a deadline; on expiry the
 * caller's budget and interrupt checks run and the trial's cleanup still
 * deletes the machine (a lost create is found by the run id at exit).
 */
const inFlight = new Set<Promise<unknown>>();

function bounded<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  // The provider request cannot be cancelled, so it stays tracked until it
  // settles and teardown waits for it before listing the inventory.
  inFlight.add(promise);
  promise.then(() => inFlight.delete(promise), () => inFlight.delete(promise));
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} exceeded ${ms} ms`)), ms);
  });
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}

/** Waits (bounded) for every timed-out provider request to settle; false when some are still running. */
async function waitForInFlight(ms: number): Promise<boolean> {
  if (inFlight.size === 0) return true;
  console.error(`cleanup_waiting_for_in_flight=${inFlight.size}`);
  // The deadline timer is cleared once the requests settle, or it would keep
  // the process alive for the rest of the wait after the report is written.
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<void>((resolve) => {
    timer = setTimeout(resolve, ms);
  });
  try {
    await Promise.race([Promise.allSettled([...inFlight]), deadline]);
  } finally {
    clearTimeout(timer);
  }
  return inFlight.size === 0;
}

/** As above, and a request still running afterwards is recorded as a cleanup failure. */
async function settleInFlight(ms: number): Promise<void> {
  if (!(await waitForInFlight(ms))) cleanupFailures.push(`${inFlight.size} provider request(s) still in flight after ${ms} ms`);
}

/** Polls until the VM reports `paused` (a `pausing` machine would race the start). */
async function waitForPaused(vm: Vm, budgetMs = 60_000): Promise<string> {
  const startedAt = performance.now();
  let state = "";
  while (performance.now() - startedAt < budgetMs) {
    state = (await bounded(vm.data(), 30_000, "data")).state;
    if (state === "paused") return state;
    if (state !== "pausing") throw new Error(`pause left the VM ${state}`);
    await new Promise((resolve) => setTimeout(resolve, PROBE_INTERVAL_MS));
  }
  throw new Error(`VM still ${state} ${budgetMs} ms after pause`);
}

async function timed<T>(run: () => Promise<T>): Promise<{ ms: number; value: T }> {
  const startedAt = performance.now();
  const value = await run();
  return { ms: elapsedMs(startedAt), value };
}

async function exec(vm: Vm, command: string, timeoutMs = 10_000): Promise<{ ms: number; exitCode: number | null; stdout: string }> {
  const { ms, value } = await timed(() => bounded(vm.exec({ command, timeoutMs, linuxUser: "root" }), timeoutMs + 15_000, "exec"));
  return { ms, exitCode: value.statusCode ?? null, stdout: (value.stdout ?? "").trim() };
}

/** A required guest command: a non-zero exit fails the trial instead of becoming a sample. */
async function execOk(vm: Vm, command: string, label: string, timeoutMs = 10_000) {
  const result = await exec(vm, command, timeoutMs);
  if (result.exitCode !== 0) throw new Error(`${label} exited ${result.exitCode ?? "timeout"}`);
  return result;
}

async function probe(vm: Vm, instanceId: string | null): Promise<Probe> {
  try {
    const result = await exec(vm, probeCommand(instanceId), 6_000);
    const [listening, running, valid, id] = result.stdout.split(" ");
    const healthy = listening === "1" && running === "1" && valid === "1";
    return { ms: result.ms, execOk: result.exitCode === 0, listening: listening === "1", running: running === "1", healthy, instanceId: id || null };
  } catch {
    return { ms: 0, execOk: false, listening: false, running: false, healthy: false, instanceId: null };
  }
}

/**
 * Polls the guest until the daemon process runs and, bound to this machine's
 * instance id, listens on 1337; returns milestone offsets from `origin`.
 * `daemonProcessMs` is the first sighting of any daemon process (a clone can
 * briefly show the source machine's); `daemonListenMs` requires the image's
 * health predicate, so only the daemon that is valid for this machine counts.
 */
async function waitForDaemon(vm: Vm, origin: number, budgetMs = 90_000, knownInstanceId: string | null = null): Promise<DaemonMilestones> {
  const milestones: DaemonMilestones = { firstExecMs: null, daemonProcessMs: null, daemonListenMs: null, probeAttempts: 0, instanceId: knownInstanceId };
  while (performance.now() - origin < budgetMs) {
    milestones.probeAttempts += 1;
    const result = await probe(vm, milestones.instanceId);
    if (milestones.instanceId === null && result.instanceId !== null) milestones.instanceId = result.instanceId;
    const at = elapsedMs(origin);
    if (result.execOk && milestones.firstExecMs === null) milestones.firstExecMs = at;
    if (result.running && milestones.daemonProcessMs === null) milestones.daemonProcessMs = at;
    if (result.healthy && milestones.daemonListenMs === null) milestones.daemonListenMs = at;
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
  // Pages are listed with retries and every id found so far is deleted even
  // when a later page fails; an incomplete inventory is then a cleanup
  // failure of its own, never a silent "nothing left".
  const ids = new Set<string>();
  let listingError: string | null = null;
  let offset = 0;
  let total = Number.POSITIVE_INFINITY;
  while (offset < total && offset < 100_000 && listingError === null) {
    let page: Awaited<ReturnType<typeof fs.vms.list>> | null = null;
    for (let attempt = 0; attempt < 3 && page === null; attempt += 1) {
      try {
        page = await bounded(fs.vms.list({ metadata: `cmux:bench,run:${runId}`, limit: 200, offset }), 60_000, "list");
      } catch (error) {
        if (attempt === 2) listingError = error instanceof Error ? error.message : String(error);
        else await new Promise((resolve) => setTimeout(resolve, 1_500));
      }
    }
    if (page === null) break;
    for (const data of page.vms) ids.add(data.id);
    total = typeof page.totalCount === "number" ? page.totalCount : (page.vms.length < 200 ? offset + page.vms.length : total);
    if (page.vms.length === 0) break;
    offset += page.vms.length;
  }
  for (const id of ids) {
    console.error(`cleanup_reconcile_vm=${id}`);
    await deleteVm(fs.vms.ref(id), id);
  }
  if (listingError !== null) cleanupFailures.push(`list run machines: ${listingError}`);
  else if (offset < total) cleanupFailures.push(`list run machines: inventory truncated at ${offset} of ${total}`);
}

/** Whether a network with this slug exists; a 404 is "no", anything else is an error. */
async function networkExists(slug: string): Promise<boolean> {
  try {
    await bounded(fs.vpc.get(slug), 30_000, "vpc get");
    return true;
  } catch (error) {
    if (error instanceof FreestyleApiError && error.status === 404) return false;
    throw error;
  }
}

/**
 * Deletes this run's VPC. Without an id in hand (the create's response was
 * lost) the network is read back by the run's slug and deleted only when it
 * is provably this run's: no network carried the slug before the create, and
 * the create labelled it with the run id. A 404 means nothing was made.
 */
async function deleteRunVpc(id: string | null): Promise<void> {
  let target = id;
  if (target === null) {
    let found: Awaited<ReturnType<typeof fs.vpc.get>>;
    try {
      found = await bounded(fs.vpc.get(runId), 30_000, "vpc get");
    } catch (error) {
      if (error instanceof FreestyleApiError && error.status === 404) return;
      throw error;
    }
    if (found.displayName !== runId) throw new Error(`network ${found.id} carries slug ${runId} but is not labelled by this run; not deleting it`);
    target = found.id;
  }
  try {
    await deleteVpcWithRetry(target);
  } catch (error) {
    if (!(error instanceof FreestyleApiError && error.status === 404)) throw error;
  }
}

/** A VM delete releases its VPC addresses asynchronously; the VPC delete answers 409 until then. */
async function deleteVpcWithRetry(id: string): Promise<void> {
  for (let attempt = 0; attempt < 12; attempt += 1) {
    try {
      await bounded(fs.vpc.delete(id), 60_000, "vpc delete");
      return;
    } catch (error) {
      if (!(error instanceof FreestyleApiError && error.status === 409) || attempt === 11) throw error;
      await new Promise((resolve) => setTimeout(resolve, 2_500));
    }
  }
}

async function createVm(vpcId: string | null, name: string) {
  const { ms, value } = await timed(() => bounded(fs.vms.create({
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
  }), 120_000, "create"));
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
    await bounded(vm.delete(), 60_000, "delete");
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
    trial.dataRtt = await repeat(3, async () => (await timed(() => bounded(vm.data(), 30_000, "data"))).ms);
    const payload = "#!/bin/sh\n".padEnd(20_480, "#");
    trial.fsWriteRtt = await repeat(3, async () => (await timed(() => bounded(vm.fs.writeTextFile(`/tmp/${runId}-shim`, payload, { mode: 0o755 }), 30_000, "fs write"))).ms);
    trial.loginShellGuestMs = await repeat(3, () => guestShellMs(vm, LOGIN_SHELL_MS, "login shell"));
    trial.interactivePtyGuestMs = await repeat(3, () => guestShellMs(vm, INTERACTIVE_PTY_MS, "interactive shell"));
    checkInterrupted();
    const paused = await timed(() => bounded(vm.pause(), 60_000, "pause"));
    trial.pauseMs = paused.ms;
    trial.stateAfterPause = paused.value.state;
    if (paused.value.state !== "paused" && paused.value.state !== "pausing") throw new Error(`pause left the VM ${paused.value.state}`);
    if (paused.value.state === "pausing") trial.stateAfterPause = await waitForPaused(vm);
    const resumeOrigin = performance.now();
    const started = await timed(() => bounded(vm.start(), 120_000, "start"));
    trial.startMs = started.ms;
    trial.stateAfterStart = started.value.state;
    // The same machine keeps its instance id across pause/start.
    const afterResume = await waitForDaemon(vm, resumeOrigin, 60_000, boot.instanceId);
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
// True only when the VPC create's response was lost (timeout, transport
// failure): the network may exist under the run's slug with no id in hand.
// A definitive provider answer, a conflict above all, means it is not ours.
let vpcCreateLost = false;
const results: { sequential: Trial[]; burst: Trial[] } = { sequential: [], burst: [] };
try {
  if (withVpc) {
    // Ownership first: nothing may carry this run's slug before the run
    // creates it, or teardown's slug fallback could delete a network this
    // run did not make.
    if (await networkExists(runId)) {
      console.error(`bench-freestyle-floor: a network with slug ${runId} already exists; refusing to adopt it`);
      process.exit(2);
    }
    let created: Awaited<ReturnType<typeof timed<Awaited<ReturnType<typeof fs.vpc.create>>>>>;
    try {
      created = await timed(() => bounded(fs.vpc.create({ slug: runId, displayName: runId, firewall: { rules: FREESTYLE_NETWORK_FIREWALL_RULES } }), 120_000, "vpc create"));
    } catch (error) {
      vpcCreateLost = !(error instanceof FreestyleApiError);
      throw error;
    }
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
  await settleInFlight(300_000);
  await reconcileRunVms();
  // Reconciliation's own deletes are bounded too: one that timed out is
  // still running at the provider, and the VPC delete below would race it
  // (409 until the machine's addresses are released), so wait for those as
  // well before touching the VPC.
  await settleInFlight(120_000);
  if (withVpc && (vpcId !== null || vpcCreateLost)) {
    await deleteRunVpc(vpcId).catch((error: unknown) => {
      cleanupFailures.push(`VPC ${vpcId ?? runId}: ${error instanceof Error ? error.message : String(error)}`);
      console.error(`cleanup_needed_vpc=${vpcId ?? runId}`);
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
writeSync(2, `${formatSummary({ ...summary.sequential, ...summary.guest, ...Object.fromEntries(Object.entries(summary.burstSummary).map(([name, value]) => [`burst:${name}`, value])) })}\n`);
const text = JSON.stringify(summary);
if (outPath) writeFileSync(outPath, `${text}\n`);
writeSync(1, `${text}\n`);
// A provider request that outlived its bound is at worst a delete still in
// progress: the report has already named it as a cleanup failure, and the
// process waits (bounded) for it to settle so that delete can complete. It
// then exits explicitly, because the SDK follows a 202 with a referenced
// timer it never cancels, which would otherwise keep the process alive
// indefinitely. The report went out with synchronous writes, so the exit
// cannot truncate it.
if (!(await waitForInFlight(600_000))) console.error(`cleanup_still_in_flight=${inFlight.size} at exit`);
process.exit(summary.ok ? 0 : 1);
