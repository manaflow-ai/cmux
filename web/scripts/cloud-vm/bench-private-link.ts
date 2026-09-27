#!/usr/bin/env bun
/**
 * Transport-level startup benchmark (issue #12905): the same private carrier
 * the Mac app uses, driven headlessly. For each trial it creates a machine
 * through the production driver (`FreestyleProvider.create`, so the guest
 * shim and reporter installs are included), mints the attach bundle
 * (`openCmuxRemote`, the attach-endpoint's provider half), dials the daemon
 * over the WireGuard hub with `cmux-tui remote connect --carrier`, reads the
 * session snapshot, starts `bash -l` in the machine's workspace, waits for the
 * prompt, then reconnects once more and destroys the machine.
 *
 *   FREESTYLE_API_KEY=… bun scripts/cloud-vm/bench-private-link.ts [--trials N] [--size md] [--image sh-…] [--client <cmux-tui>] [--out <file.json>]
 *
 * The provider credential is read the way the runtime's client reads it:
 * FREESTYLE_API_KEY, or FREESTYLE_STACK_ACCESS_TOKEN with FREESTYLE_TEAM_ID
 * (source ~/.secrets/cmux.env).
 *
 * Scope: the transport path without the control plane. Production's create
 * also carries two inline `tls` edge rules (the coderouter alias and the
 * reflection alias, each routing to the deployment's API host with the
 * machine's model-plane token headers, services/coderouter/vmModelPlane.ts),
 * which need a deployment's secrets to mint. This benchmark's create omits
 * them, so its create timing excludes whatever the platform charges to
 * attach two edge rules, and the guest has no model-plane credential; the
 * control-plane benchmark (bench-vm-startup.mjs) measures the create with
 * them, as `provider_create` in the route's Server-Timing.
 *
 * Creates its own VPC, tunnel and machines and deletes them, including on
 * failure. Never modifies existing machines. Modeled on
 * verify-devbox-private-link.ts.
 */
import { Duration, Effect, Schedule } from "effect";
import { Freestyle, FreestyleApiError } from "freestyle";
import { spawn } from "node:child_process";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { cleanupPrivateLinkResource as cleanup } from "../devbox-private-link-cleanup";
import { startPrivateLinkClient } from "../devbox-private-link-process";
import { FREESTYLE_NETWORK_FIREWALL_RULES, FreestyleProvider } from "../../services/vms/drivers/freestyle";
import { ProviderError } from "../../services/vms/drivers/types";
import type { GuestPromptIdentity } from "../../services/vms/guestPrompt";
import { resolveVmImage } from "../../services/vms/images/resolver";
import { isVmImageSizeName, vmImageSize } from "../../services/vms/images/sizes";
import { elapsedMs, formatSummary, pollBoundedFetch, providerCredentialsFromEnv, summarizeFields } from "./benchStats.mjs";

type Trial = Record<string, unknown> & { index: number };

const args = process.argv.slice(2);
const option = (flag: string): string | undefined => {
  const at = args.indexOf(flag);
  return at === -1 ? undefined : args[at + 1];
};
const trials = Number(option("--trials") ?? "2");
const sizeName = option("--size") ?? "md";
const client = path.resolve(option("--client") ?? "/Applications/cmux Nightly.app/Contents/Resources/bin/cmux-tui");
const outPath = option("--out");
if (!Number.isInteger(trials) || trials < 1 || !isVmImageSizeName(sizeName)) {
  console.error("bench-private-link: --trials takes a positive integer; --size is sm|md|lg|lgx|xl|2xl");
  process.exit(2);
}
const size = vmImageSize(sizeName);
// The runtime's credential forms (API key, or Stack access token with a
// team id). Every SDK request, the driver's included, is bounded (a
// per-fetch timeout) and the SDK's polling of a backgrounded request ends
// at a deadline, so no tracked request can stay in flight forever and the
// settle waits are bounded by construction.
function exitWithoutProviderCredentials(): never {
  console.error("bench-private-link: FREESTYLE_API_KEY, or FREESTYLE_STACK_ACCESS_TOKEN with FREESTYLE_TEAM_ID, is required (source ~/.secrets/cmux.env)");
  process.exit(2);
}
const providerCredentials = providerCredentialsFromEnv() ?? exitWithoutProviderCredentials();
const POLL_DEADLINE_MS = 15 * 60 * 1000;
// Background requests abandoned at the polling deadline, across every client
// this run builds: they settled here but may still complete at the platform,
// so the run reports each one and fails while any exists.
const abandonedPolls = new Set<string>();
const providerClient = (timeoutMs = 60_000): Freestyle => new Freestyle({ ...providerCredentials, fetch: pollBoundedFetch({ fetchTimeoutMs: timeoutMs, pollDeadlineMs: POLL_DEADLINE_MS, abandoned: abandonedPolls }).fetch });
const sdk = providerClient();
const selection = resolveVmImage("freestyle", option("--image"), process.env, { kind: "desktop", memoryMb: size.memoryMb });
const image = selection.image;
const PROMPT_PATTERN = "λ";
const runId = randomUUID().slice(0, 8);
// Provider requests cannot be cancelled: each create and each finalizer's
// delete is tracked until it settles, and the slug-based safety net waits for
// them before it lists the inventory and deletes the VPC, so an interrupted
// or timed-out create cannot allocate behind the sweep and a timed-out delete
// cannot race the VPC delete.
const inFlight = new Set<Promise<unknown>>();
function tracked<T>(promise: Promise<T>): Promise<T> {
  inFlight.add(promise);
  promise.then(() => inFlight.delete(promise), () => inFlight.delete(promise));
  return promise;
}
/** A tracked provider request raced against a deadline; the request itself keeps running until it settles. */
function bounded<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  tracked(promise);
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
/**
 * Blocks until every tracked provider request has settled, reporting every
 * ten minutes. A mutation the SDK cannot cancel must never be swept past or
 * abandoned: a create or delete that completed after an inventory read
 * would leave a resource behind. The wait is bounded by construction: the
 * client's fetch timeout and polling deadline (pollBoundedFetch) settle
 * every request within about the deadline.
 */
async function waitUntilSettled(): Promise<void> {
  while (!(await waitForInFlight(600_000))) console.error(`cleanup_still_in_flight=${inFlight.size} (waiting for them to settle)`);
}

const attempt = <A>(label: string, run: (signal: AbortSignal) => Promise<A>) =>
  Effect.tryPromise({ try: run, catch: (error) => new Error(`${label}: ${error instanceof Error ? error.message : String(error)}`) });

/**
 * An `attempt` with a deadline: the SDK polls a backgrounded request
 * indefinitely, so a cleanup call must not wait on it forever. Finalizers
 * run with interruption masked and a timeout is an interrupt, so the attempt
 * is made interruptible first (as `cleanupPrivateLinkResource` does); the
 * abandoned request keeps running and stays tracked where that matters.
 */
const attemptWithin = <A>(label: string, run: (signal: AbortSignal) => Promise<A>, timeout: Duration.DurationInput) =>
  attempt(label, run).pipe(
    Effect.interruptible,
    Effect.timeoutFail({ duration: timeout, onTimeout: () => new Error(`${label}: timed out`) }),
  );

/** A synchronous check whose throw must fail the trial (recorded, run continues), not become a defect that aborts the whole run. */
const validated = <A>(check: () => A) =>
  Effect.try({ try: check, catch: (error) => (error instanceof Error ? error : new Error(String(error))) });

/** One bounded client command over the link's local socket; stdout is the result. */
function command(clientPath: string, commandArgs: string[], label: string, timeout: Duration.DurationInput = "30 seconds") {
  return attempt(label, (signal) => new Promise<string>((resolve, reject) => {
    const child = spawn(clientPath, commandArgs, { signal, stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    child.stdout!.on("data", (chunk: Buffer) => {
      output += chunk.toString();
      if (output.length > 1_048_576) { child.kill(); reject(new Error(label)); }
    });
    child.stderr!.resume();
    child.once("error", reject);
    child.once("close", (code) => code === 0 ? resolve(output) : reject(new Error(`${label} (exit ${code})`)));
  })).pipe(Effect.timeoutFail({ duration: timeout, onTimeout: () => new Error(`${label}: timed out`) }));
}

const timed = <A, E, R>(effect: Effect.Effect<A, E, R>) => Effect.gen(function* () {
  const startedAt = performance.now();
  const value = yield* effect;
  return { ms: elapsedMs(startedAt), value };
});

function linkArgs(route: string, root: string, hubSocket: string, socket: string): string[] {
  return ["remote", "connect", route, "--carrier", "--state-dir", path.join(root, "identity"), "--device-name", `bench-${randomUUID().slice(0, 8)}`,
    "--headless", "--json", "--wireguard-hub", hubSocket, "--connect-timeout-seconds", "60", "--reconnect-attempts", "3", "--local-socket", socket];
}

function terminalId(runOutput: string): string {
  const parsed = JSON.parse(runOutput) as Record<string, unknown>;
  const value = (parsed.value as Record<string, unknown> | undefined) ?? parsed;
  const id = value.terminal_id;
  if (typeof id !== "string" || id === "") throw new Error("workspace run returned no terminal_id");
  return id;
}

/** `terminal … screen wait` answers `{matched:false}` with exit 0 when its timeout expires. */
function requireMatched(waitOutput: string): void {
  const parsed = JSON.parse(waitOutput) as Record<string, unknown>;
  const value = (parsed.value as Record<string, unknown> | undefined) ?? parsed;
  if (value.matched !== true) throw new Error("the prompt did not appear before the screen wait timed out");
}

/** The daemon's focused (else first) workspace id; a snapshot without one fails the trial rather than measuring an implicit context. */
function workspaceId(snapshot: string): string {
  const parsed = JSON.parse(snapshot) as { workspaces?: Array<{ id?: string; focused?: boolean }> };
  const workspaces = parsed.workspaces ?? [];
  const focused = workspaces.find((workspace) => workspace.focused) ?? workspaces[0];
  if (typeof focused?.id !== "string" || focused.id === "") throw new Error("session snapshot carries no workspace id");
  return focused.id;
}

/**
 * What the run knows about its network and tunnel creates. A create that
 * lost its response (timeout, transport failure, any answer but a 409
 * conflict) may have made a resource under the run's slug with no id in
 * hand; a conflict proves the resource is not ours; a successful create is
 * deleted by id by its own finalizer. Only a lost response lets the safety
 * net below look anything up by slug, and the created ids let it delete the
 * tunnel and the network again after their own finalizers.
 */
type RunNetworkState = { networkLost: boolean; tunnelLost: boolean; networkId: string | null; tunnelId: string | null; networkMark: string };

/**
 * Safety net for a VPC or tunnel whose create response was lost before its
 * acquireRelease finalizer existed: both carry this run's slug, so they are
 * found by name and removed (machines on the VPC first), but only for a
 * create marked lost, and only when they also carry the run's own marks (the
 * network a label independent of the slug that only this run's create
 * wrote, the tunnel the run's client key); anything else
 * with the slug is reported and left alone. Registered before anything is
 * created, so it runs after every other finalizer; every step treats "not
 * found" as done.
 */
function reconcileRunNetworkBySlug(provider: FreestyleProvider, slug: string, clientPublicKey: string, state: RunNetworkState) {
  const networking = provider.privateNetworking;
  // One pass of the net: every tracked provider request has settled before
  // anything is listed or deleted (a create or delete still in flight could
  // otherwise complete after the sweep; the wait is unbounded and reports
  // every ten minutes, because sweeping past a mutation the SDK cannot
  // cancel would abandon it), then the lost tunnel, the known tunnel, the
  // known network (its machines swept again first) and the lost network.
  const pass = Effect.gen(function* () {
    const failures: string[] = [];
    yield* attempt("settle in-flight provider requests", () => waitUntilSettled());
    const tunnels = state.tunnelLost
      ? yield* Effect.either(attemptWithin("list tunnels", () => sdk.tunnels.list(), "60 seconds"))
      : null;
    if (tunnels === null) {
      // Nothing to look up: the tunnel create either answered (its finalizer
      // owns a created tunnel; a refused one is not ours) or never ran.
    } else if (tunnels._tag === "Left") failures.push(tunnels.left.message);
    else {
      for (const tunnel of tunnels.right.tunnels ?? []) {
        if (tunnel.slug !== slug) continue;
        const id = tunnel.tunnelId ?? tunnel.id;
        if (tunnel.clientPublicKey !== clientPublicKey) {
          failures.push(`tunnel ${id} carries slug ${slug} but another client key; not deleting it`);
          continue;
        }
        console.error(`cleanup_reconcile_tunnel=${id}`);
        const deleted = yield* Effect.either(attemptWithin(`delete tunnel ${id}`, () => tracked(networking.deleteTunnel(id)), "60 seconds"));
        if (deleted._tag === "Left") failures.push(deleted.left.message);
      }
    }
    if (state.tunnelId !== null) {
      // A created tunnel's own finalizer can exhaust its retries, and a
      // tunnel keeps its network attached, so the known tunnel is deleted
      // again here (idempotent: a 404 means it is gone) before the network.
      const knownTunnel = state.tunnelId;
      const deleted = yield* Effect.either(attemptWithin(`delete tunnel ${knownTunnel}`, () => tracked(networking.deleteTunnel(knownTunnel)), "60 seconds").pipe(Effect.retry({ times: 2, schedule: Schedule.spaced("2500 millis") })));
      if (deleted._tag === "Left") failures.push(deleted.left.message);
    }
    if (state.networkId !== null) {
      // Finalizers run last-registered first, so the created network's own
      // finalizer ran before this net. A tunnel whose create response was
      // lost could have kept that network attached until it was removed
      // just above, so the known network is deleted again here; a 404
      // means its own finalizer already succeeded.
      const knownId = state.networkId;
      // A machine create still in flight during the earlier sweep can have
      // allocated after it; the in-flight requests settled above, so the
      // membership sweep runs once more before the network goes.
      failures.push(...(yield* reconcileRunMachines(provider, knownId)));
      const deleted = yield* Effect.either(attemptWithin(`delete VPC ${knownId}`, () => tracked(networking.deleteNetwork(knownId)), "60 seconds").pipe(Effect.retry({ times: 11, schedule: Schedule.spaced("2500 millis") })));
      if (deleted._tag === "Left") failures.push(deleted.left.message);
    }
    const network = state.networkLost
      ? yield* Effect.either(attemptWithin("read network by slug", () => sdk.vpc.get(slug), "30 seconds"))
      : null;
    if (network === null) {
      // Same for the network: only a lost create response can have made one
      // this run does not know the id of.
    } else if (network._tag === "Right") {
      // The mark is a label independent of the slug that only this run's
      // create wrote, so a stale or colliding network that merely carries
      // the slug is never taken for ours.
      if (network.right.displayName !== state.networkMark) {
        failures.push(`network ${network.right.id} carries slug ${slug} but not this run's mark; not deleting it`);
      } else {
        console.error(`cleanup_reconcile_network=${network.right.id}`);
        failures.push(...(yield* reconcileRunMachines(provider, network.right.id)));
        const deleted = yield* Effect.either(attemptWithin(`delete VPC ${slug}`, () => tracked(networking.deleteNetwork(network.right.id)), "60 seconds").pipe(Effect.retry({ times: 11, schedule: Schedule.spaced("2500 millis") })));
        if (deleted._tag === "Left") failures.push(deleted.left.message);
      }
    } else if (!/404|not found/i.test(network.left.message)) {
      failures.push(network.left.message);
    }
    return failures;
  });
  // The pass runs once more when it recorded a failure (its own deletes are
  // bounded and may have timed out while still running), so a delete that
  // completed late still ends with an empty network and nothing attached.
  return Effect.gen(function* () {
    let failures = yield* pass;
    if (failures.length > 0) {
      console.error(`cleanup_pass=1 recorded ${failures.length} failure(s); running the pass again once the requests settle`);
      failures = yield* pass;
    }
    for (const url of abandonedPolls) console.error(`cleanup_unresolved_provider_request=${url}`);
    if (abandonedPolls.size > 0) {
      failures.push(`${abandonedPolls.size} provider background request(s) abandoned past the polling deadline; their operations may still complete: ${[...abandonedPolls].join(", ")}`);
    }
    if (failures.length > 0) {
      for (const failure of failures) console.error(`cleanup_reconcile_failed ${failure}`);
      return yield* Effect.fail(new Error(`cleanup incomplete: ${failures.join("; ")}`));
    }
  }).pipe(Effect.orDie);
}

function runTrial(index: number, provider: FreestyleProvider, networkId: string, root: string, hubSocket: string, capabilities: string[]) {
  return Effect.scoped(Effect.gen(function* () {
    const trial: Trial = { index, image, size: size.name, startedAt: new Date().toISOString() };
    const origin = performance.now();
    // The production workflow hands the machine's prompt identity to both the
    // create and the attach (the guest installs its prompt each time) and
    // feeds the addresses persisted at create back into the attach, which
    // then skips a provider read; the benchmark does the same work and the
    // same round trips so it measures the transport path, not a lighter one.
    const promptIdentity: GuestPromptIdentity = { machineId: randomUUID(), name: `bench-link-${runId}-${index}`, revision: Date.now() };
    // acquireRelease: the create cannot be interrupted half-way (the provider
    // request is not cancellable, so an interrupt waits for it) and the
    // destroy finalizer is registered atomically with the machine's id.
    const created = yield* timed(Effect.acquireRelease(
      attempt("provider.create", () => bounded(provider.create({
        image, network: { id: networkId }, displayName: `bench-link-${runId}-${index}`, imageSize: selection.size ?? undefined, promptIdentity,
      }), 900_000, "provider.create")),
      (value) => Effect.gen(function* () {
        const destroyed = yield* timed(cleanup(`VM ${value.providerVmId}`, () => tracked(provider.destroy(value.providerVmId))));
        trial.destroyMs = destroyed.ms;
      }),
    ));
    const vmId = created.value.providerVmId;
    trial.vmId = vmId;
    trial.createMs = created.ms;
    // Bounded and tracked like the create: the attach bundle's provider calls
    // can be backgrounded too, and an abandoned attach must settle before the
    // sweep. The bound is the platform limit the app's attach route runs under.
    const attached = yield* timed(attempt("openCmuxRemote", () => bounded(provider.openCmuxRemote(vmId, {
      clientCapabilities: capabilities, promptIdentity, providerMetadata: created.value.providerMetadata,
    }), 300_000, "openCmuxRemote")));
    trial.attachMs = attached.ms;
    trial.trustedCarrier = attached.value.trustedCarrier;
    trial.daemonCommit = attached.value.daemonBuild?.commit ?? null;
    trial.createToAttachedMs = elapsedMs(origin);
    if (!attached.value.trustedCarrier) return yield* Effect.fail(new Error("fresh VM does not serve the trusted-carrier listener"));
    const route = attached.value.route;
    const firstSocket = path.join(root, `link-${index}-a.sock`);
    const first = yield* Effect.scoped(Effect.gen(function* () {
      const link = yield* timed(Effect.gen(function* () {
        const connection = yield* startPrivateLinkClient(client, linkArgs(route, root, hubSocket, firstSocket), { event: "connection-snapshot", socket: firstSocket });
        yield* connection.ready;
      }));
      const snapshot = yield* timed(command(client, ["--socket", firstSocket, "--json", "session", "current", "snapshot"], "session snapshot"));
      const workspace = yield* validated(() => workspaceId(snapshot.value));
      const runStartedAt = performance.now();
      const run = yield* timed(command(client, ["--socket", firstSocket, "--json", "workspace", workspace, "run", "--", "bash", "-l"], "workspace run"));
      const terminal = yield* validated(() => terminalId(run.value));
      const prompt = yield* timed(command(client, ["--socket", firstSocket, "--json", "terminal", terminal, "screen", "wait", "--pattern", PROMPT_PATTERN, "--timeout-ms", "60000"], "prompt wait", "70 seconds"));
      yield* validated(() => requireMatched(prompt.value));
      // Read the clock here, before the scope closes the first link: its
      // teardown (up to a 2 s SIGKILL escalation) is not startup.
      return { linkMs: link.ms, snapshotMs: snapshot.ms, terminalRunMs: run.ms, promptWaitMs: prompt.ms, runToPromptMs: elapsedMs(runStartedAt), createToPromptMs: elapsedMs(origin) };
    }));
    Object.assign(trial, first);
    const secondSocket = path.join(root, `link-${index}-b.sock`);
    const reconnect = yield* timed(Effect.gen(function* () {
      const connection = yield* startPrivateLinkClient(client, linkArgs(route, root, hubSocket, secondSocket), { event: "connection-snapshot", socket: secondSocket });
      yield* connection.ready;
    }));
    trial.reconnectLinkMs = reconnect.ms;
    return trial;
  }));
}

/**
 * Destroys every machine still attached to the benchmark's VPC. The driver
 * names every machine "cmux Cloud VM", so the VPC (created by and only for
 * this run) is the one identity the provider persists for them.
 */
function reconcileRunMachines(provider: FreestyleProvider, networkId: string) {
  // Pages are read with retries; the ids found before a failed page are kept
  // so they are still destroyed, and an incomplete inventory is reported as
  // its own failure.
  const listRunMachines = Effect.gen(function* () {
    const ids: string[] = [];
    let listingError: string | null = null;
    let offset = 0;
    let total = Number.POSITIVE_INFINITY;
    while (offset < total && offset < 100_000 && listingError === null) {
      const page = yield* Effect.either(
        attemptWithin("list machines", () => sdk.vms.list({ metadata: "cmux:cloud", limit: 200, offset }), "60 seconds").pipe(Effect.retry({ times: 2, schedule: Schedule.spaced("1500 millis") })),
      );
      if (page._tag === "Left") { listingError = page.left.message; break; }
      for (const data of page.right.vms) {
        const networks = data.vpcs ?? data.networks ?? [];
        if (networks.some((network) => (network.vpcId ?? network.vpc) === networkId)) ids.push(data.id);
      }
      total = typeof page.right.totalCount === "number" ? page.right.totalCount : (page.right.vms.length < 200 ? offset + page.right.vms.length : total);
      if (page.right.vms.length === 0) break;
      offset += page.right.vms.length;
    }
    if (listingError === null && offset < total) listingError = `inventory truncated at ${offset} of ${total}`;
    return { ids, listingError };
  });
  // Every discovered machine is attempted; the failures are returned so the
  // caller can fail the run instead of reporting a clean teardown over a
  // machine it could not remove.
  return Effect.gen(function* () {
    const failures: string[] = [];
    const listed = yield* listRunMachines;
    if (listed.listingError !== null) failures.push(`list machines: ${listed.listingError}`);
    for (const id of listed.ids) {
      console.error(`cleanup_reconcile_vm=${id}`);
      const destroyed = yield* Effect.either(
        attemptWithin(`destroy ${id}`, () => tracked(provider.destroy(id)), "120 seconds").pipe(Effect.retry({ times: 2, schedule: Schedule.spaced("2500 millis") })),
      );
      if (destroyed._tag === "Left") failures.push(destroyed.left.message);
    }
    for (const failure of failures) console.error(`cleanup_reconcile_failed ${failure}`);
    return failures;
  });
}

/** The machine sweep as a finalizer: an incomplete sweep fails the run. */
function reconcileRunMachinesOrDie(provider: FreestyleProvider, networkId: string) {
  return reconcileRunMachines(provider, networkId).pipe(
    Effect.flatMap((failures) => (failures.length > 0 ? Effect.die(new Error(`cleanup incomplete: ${failures.join("; ")}`)) : Effect.void)),
  );
}

function bench() {
  return Effect.gen(function* () {
    const rawProbe = yield* command(client, ["remote-probe", "--json"], "client probe");
    const probe = JSON.parse(rawProbe) as { app?: string; capabilities?: string[]; build_identity?: string };
    if (probe.app !== "cmux-tui" || !probe.capabilities?.includes("wireguard-hub")) {
      return yield* Effect.fail(new Error("the client lacks wireguard-hub; point --client at a current cmux-tui"));
    }
    // The production driver on the same bounded client, so its create,
    // attach and destroy requests settle within the polling deadline too.
    const provider = new FreestyleProvider({ client: providerClient });
    const networking = provider.privateNetworking;
    const root = yield* Effect.acquireRelease(
      Effect.sync(() => mkdtempSync(path.join(tmpdir(), "cmux-bench-link-"))),
      (directory) => Effect.sync(() => rmSync(directory, { recursive: true, force: true })),
    );
    const slug = `cmux-bench-link-${runId}`;
    // The run's own key pair doubles as its tunnel's ownership proof.
    const { privateKey, publicKey } = generateKeyPairSync("x25519");
    const clientPublicKey = publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64");
    const privateBytes = privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32).toString("base64");
    const state: RunNetworkState = { networkLost: false, tunnelLost: false, networkId: null, tunnelId: null, networkMark: `${slug} ${randomUUID()}` };
    yield* Effect.addFinalizer(() => reconcileRunNetworkBySlug(provider, slug, clientPublicKey, state));
    // The network is made with the SDK's plain create, which fails closed on
    // a slug conflict, not with the driver's ensureNetwork, which adopts an
    // existing network on conflict: a successful create is the only proof
    // that the network, and everything the finalizers later delete by its
    // id, is this run's. The rules are production's. Only a conflict (409)
    // proves the network is not ours; any other failure, a 5xx above all,
    // may have made it and marks the create lost for the safety net.
    const network = yield* timed(Effect.acquireRelease(
      attempt("vpc.create", () => {
        const request = sdk.vpc.create({ slug, displayName: state.networkMark, firewall: { rules: FREESTYLE_NETWORK_FIREWALL_RULES } });
        // The id is recorded on the request itself: no fiber interrupt can
        // skip a promise continuation (acquireRelease also runs this acquire
        // uninterruptibly), and a request whose bound expired still resolves
        // later, so a network created after the bound is deleted by id as
        // well as found by slug.
        request.then((created) => { state.networkId ??= created.data.id; }, () => {});
        return bounded(request, 120_000, "vpc.create").catch((error: unknown) => {
          state.networkLost = !(error instanceof FreestyleApiError && error.status === 409);
          throw error;
        });
      }).pipe(Effect.map((created) => ({ id: created.data.id }))),
      (value) => cleanup(`VPC ${value.id}`, () => tracked(networking.deleteNetwork(value.id))),
    ));
    // Registered right after the VPC so it runs before the VPC delete: any
    // machine of this run that survived its own finalizer (a create whose
    // response was lost) is found by its membership in the benchmark-owned
    // VPC and destroyed.
    yield* Effect.addFinalizer(() => reconcileRunMachinesOrDie(provider, network.value.id));
    // The driver recovers an existing tunnel only for the same client key,
    // and this run's key is fresh: a slug conflict with another key fails,
    // while a recovered tunnel carries this run's key and is therefore this
    // run's (a create whose response was lost, then retried), so it is
    // deleted exactly like a created one.
    const tunnel = yield* timed(Effect.acquireRelease(
      attempt("createTunnel", () => {
        const request = networking.createTunnel({ slug, networkId: network.value.id, clientPublicKey });
        // Recorded on the request itself, for the same reasons as the network's id.
        request.then((value) => { state.tunnelId ??= value.tunnel.id; }, () => {});
        return bounded(request, 120_000, "createTunnel").catch((error: unknown) => {
          // Only a conflict (409, wrapped by the driver in ProviderError)
          // proves the tunnel is not ours; anything else, a 5xx above all, may
          // have made it and marks the create lost for the safety net.
          state.tunnelLost = !(error instanceof ProviderError && error.cause instanceof FreestyleApiError && error.cause.status === 409);
          throw error;
        });
      }),
      (value) => cleanup(`tunnel ${value.tunnel.id}`, () => tracked(networking.deleteTunnel(value.tunnel.id))),
    ));
    const config = tunnel.value.tunnel.clientConfig.replace(/^PrivateKey\s*=.*$/m, `PrivateKey = ${privateBytes}`);
    const configPath = path.join(root, "wg.conf");
    const hubSocket = path.join(root, "wg.sock");
    writeFileSync(configPath, config, { mode: 0o600 });
    const hub = yield* timed(Effect.gen(function* () {
      const process = yield* startPrivateLinkClient(client, ["wg", "hub", "--config", configPath, "--socket", hubSocket], { event: "hub-ready", socket: hubSocket });
      yield* process.ready;
    }));
    const results: Trial[] = [];
    for (let index = 0; index < trials; index += 1) {
      const outcome = yield* Effect.either(runTrial(index, provider, network.value.id, root, hubSocket, probe.capabilities ?? []));
      if (outcome._tag === "Right") results.push(outcome.right);
      else results.push({ index, error: outcome.left instanceof Error ? outcome.left.message : String(outcome.left) });
      console.error(`trial ${index}: ${JSON.stringify(results.at(-1))}`);
    }
    const ok = results.filter((trial) => !trial.error);
    const summary = {
      ok: ok.length === results.length,
      image,
      size: size.name,
      clientCommit: probe.build_identity ?? null,
      networkMs: network.ms,
      tunnelMs: tunnel.ms,
      hubReadyMs: hub.ms,
      stages: summarizeFields(ok, ["createMs", "attachMs", "createToAttachedMs", "linkMs", "snapshotMs", "terminalRunMs", "runToPromptMs", "createToPromptMs", "reconnectLinkMs", "destroyMs"]),
      results,
    };
    console.error(formatSummary(summary.stages));
    return summary;
  });
}

const controller = new AbortController();
const interrupt = () => controller.abort();
process.once("SIGINT", interrupt);
process.once("SIGTERM", interrupt);
try {
  const summary = await Effect.runPromise(Effect.scoped(bench()), { signal: controller.signal });
  const text = JSON.stringify(summary);
  if (outPath) writeFileSync(outPath, `${text}\n`);
  writeSync(1, `${text}\n`);
  if (!summary.ok) process.exitCode = 1;
} catch (error: unknown) {
  console.error(String(error));
  process.exitCode = 1;
} finally {
  process.off("SIGINT", interrupt);
  process.off("SIGTERM", interrupt);
}
// A provider request that outlived its bound is at worst a delete still in
// progress. The SDK cannot cancel it and exiting would abandon it, so the
// process stays alive until every tracked request has settled (the run has
// already reported them and the exit code is set), then exits explicitly,
// because the SDK's 202 polling timer would otherwise keep an idle process
// alive after everything has settled. A signal during this wait is reported
// and ignored once; a second one ends the process the default way, which is
// the operator's explicit choice to abandon the requests. The report went out
// with synchronous writes, so the exit cannot truncate it.
const warnAbandon = (signal: string) => console.error(`${signal} during the final wait: ${inFlight.size} provider request(s) still in flight; a second ${signal} abandons them`);
process.once("SIGINT", () => warnAbandon("SIGINT"));
process.once("SIGTERM", () => warnAbandon("SIGTERM"));
await waitUntilSettled();
process.exit(process.exitCode ?? 0);
