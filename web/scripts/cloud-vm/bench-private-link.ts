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
 * Creates its own VPC, tunnel and machines and deletes them, including on
 * failure. Never modifies existing machines. Modeled on
 * verify-devbox-private-link.ts.
 */
import { Duration, Effect, Schedule } from "effect";
import { Freestyle } from "freestyle";
import { spawn } from "node:child_process";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { cleanupPrivateLinkResource as cleanup } from "../devbox-private-link-cleanup";
import { startPrivateLinkClient } from "../devbox-private-link-process";
import { FreestyleProvider } from "../../services/vms/drivers/freestyle";
import { resolveVmImage } from "../../services/vms/images/resolver";
import { isVmImageSizeName, vmImageSize } from "../../services/vms/images/sizes";
import { elapsedMs, formatSummary, summarizeFields } from "./benchStats.mjs";

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
if (!process.env.FREESTYLE_API_KEY) {
  console.error("Set FREESTYLE_API_KEY (source ~/.secrets/cmux.env)");
  process.exit(2);
}
const size = vmImageSize(sizeName);
const selection = resolveVmImage("freestyle", option("--image"), process.env, { kind: "desktop", memoryMb: size.memoryMb });
const image = selection.image;
const PROMPT_PATTERN = "λ";
const runId = randomUUID().slice(0, 8);

const attempt = <A>(label: string, run: (signal: AbortSignal) => Promise<A>) =>
  Effect.tryPromise({ try: run, catch: (error) => new Error(`${label}: ${error instanceof Error ? error.message : String(error)}`) });

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

function workspaceId(snapshot: string): string {
  const parsed = JSON.parse(snapshot) as { workspaces?: Array<{ id?: string; focused?: boolean }> };
  const workspaces = parsed.workspaces ?? [];
  const focused = workspaces.find((workspace) => workspace.focused) ?? workspaces[0];
  return typeof focused?.id === "string" && focused.id !== "" ? focused.id : "current";
}

function runTrial(index: number, provider: FreestyleProvider, networkId: string, root: string, hubSocket: string, capabilities: string[]) {
  return Effect.scoped(Effect.gen(function* () {
    const trial: Trial = { index, image, size: size.name, startedAt: new Date().toISOString() };
    const origin = performance.now();
    // acquireRelease: the create cannot be interrupted half-way (the provider
    // request is not cancellable, so an interrupt waits for it) and the
    // destroy finalizer is registered atomically with the machine's id.
    const created = yield* timed(Effect.acquireRelease(
      attempt("provider.create", () => provider.create({
        image, network: { id: networkId }, displayName: `bench-link-${runId}-${index}`, imageSize: selection.size ?? undefined,
      })),
      (value) => Effect.gen(function* () {
        const destroyed = yield* timed(cleanup(`VM ${value.providerVmId}`, () => provider.destroy(value.providerVmId)));
        trial.destroyMs = destroyed.ms;
      }),
    ));
    const vmId = created.value.providerVmId;
    trial.vmId = vmId;
    trial.createMs = created.ms;
    const attached = yield* timed(attempt("openCmuxRemote", () => provider.openCmuxRemote(vmId, { clientCapabilities: capabilities })));
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
      const workspace = workspaceId(snapshot.value);
      const runStartedAt = performance.now();
      const run = yield* timed(command(client, ["--socket", firstSocket, "--json", "workspace", workspace, "run", "--", "bash", "-l"], "workspace run"));
      const terminal = terminalId(run.value);
      const prompt = yield* timed(command(client, ["--socket", firstSocket, "--json", "terminal", terminal, "screen", "wait", "--pattern", PROMPT_PATTERN, "--timeout-ms", "60000"], "prompt wait", "70 seconds"));
      requireMatched(prompt.value);
      return { linkMs: link.ms, snapshotMs: snapshot.ms, terminalRunMs: run.ms, promptWaitMs: prompt.ms, runToPromptMs: elapsedMs(runStartedAt) };
    }));
    Object.assign(trial, first);
    trial.createToPromptMs = elapsedMs(origin);
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
  const sdk = new Freestyle({ apiKey: process.env.FREESTYLE_API_KEY });
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
        attempt("list machines", () => sdk.vms.list({ metadata: "cmux:cloud", limit: 200, offset })).pipe(Effect.retry({ times: 2, schedule: Schedule.spaced("1500 millis") })),
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
  // Every discovered machine is attempted; failures are aggregated and the
  // finalizer then fails, so the run exits non-zero instead of reporting a
  // clean teardown over a machine it could not remove.
  return Effect.gen(function* () {
    const failures: string[] = [];
    const listed = yield* listRunMachines;
    if (listed.listingError !== null) failures.push(`list machines: ${listed.listingError}`);
    for (const id of listed.ids) {
      console.error(`cleanup_reconcile_vm=${id}`);
      const destroyed = yield* Effect.either(
        attempt(`destroy ${id}`, () => provider.destroy(id)).pipe(Effect.retry({ times: 2, schedule: Schedule.spaced("2500 millis") })),
      );
      if (destroyed._tag === "Left") failures.push(destroyed.left.message);
    }
    if (failures.length > 0) {
      for (const failure of failures) console.error(`cleanup_reconcile_failed ${failure}`);
      return yield* Effect.fail(new Error(`cleanup incomplete: ${failures.join("; ")}`));
    }
  }).pipe(Effect.orDie);
}

function bench() {
  return Effect.gen(function* () {
    const rawProbe = yield* command(client, ["remote-probe", "--json"], "client probe");
    const probe = JSON.parse(rawProbe) as { app?: string; capabilities?: string[]; build_identity?: string };
    if (probe.app !== "cmux-tui" || !probe.capabilities?.includes("wireguard-hub")) {
      return yield* Effect.fail(new Error("the client lacks wireguard-hub; point --client at a current cmux-tui"));
    }
    const provider = new FreestyleProvider();
    const networking = provider.privateNetworking;
    const root = yield* Effect.acquireRelease(
      Effect.sync(() => mkdtempSync(path.join(tmpdir(), "cmux-bench-link-"))),
      (directory) => Effect.sync(() => rmSync(directory, { recursive: true, force: true })),
    );
    const slug = `cmux-bench-link-${runId}`;
    const network = yield* timed(Effect.acquireRelease(
      attempt("ensureNetwork", () => networking.ensureNetwork({ slug })),
      (value) => cleanup(`VPC ${value.id}`, () => networking.deleteNetwork(value.id)),
    ));
    // Registered right after the VPC so it runs before the VPC delete: any
    // machine of this run that survived its own finalizer (a create whose
    // response was lost) is found by its membership in the benchmark-owned
    // VPC and destroyed.
    yield* Effect.addFinalizer(() => reconcileRunMachines(provider, network.value.id));
    const { privateKey, publicKey } = generateKeyPairSync("x25519");
    const clientPublicKey = publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64");
    const privateBytes = privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32).toString("base64");
    const tunnel = yield* timed(Effect.acquireRelease(
      attempt("createTunnel", () => networking.createTunnel({ slug, networkId: network.value.id, clientPublicKey })),
      (value) => cleanup(`tunnel ${value.tunnel.id}`, () => networking.deleteTunnel(value.tunnel.id)),
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
  console.log(text);
  if (!summary.ok) process.exitCode = 1;
} catch (error: unknown) {
  console.error(String(error));
  process.exitCode = 1;
} finally {
  process.off("SIGINT", interrupt);
  process.off("SIGTERM", interrupt);
}
