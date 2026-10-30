#!/usr/bin/env bun
/**
 * Maintainer-only test harness, not a shipped application command.
 * Verify an image through the same private carrier as the Mac app. Local daemon
 * readiness alone misses a stale client, VPC routing, or enrollment failure.
 *
 * bun scripts/verify-devbox-private-link.ts <snapshot-id> <cmux-tui-client> [--client-grant]
 *
 * Requires FREESTYLE_API_KEY. Creates an isolated VM, VPC, and temporary tunnel;
 * deletes all three, including on failure. Never modifies existing machines.
 * Uses the supplied client on macOS or Linux, without installing a system VPN.
 */
import { Effect } from "effect";
import { spawn } from "node:child_process";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { cleanupPrivateLinkResource as cleanup } from "./devbox-private-link-cleanup";
import { startPrivateLinkClient } from "./devbox-private-link-process";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import type { CmuxRemoteEndpoint } from "../services/vms/drivers/types";

/** Convert provider failures to local operator stage labels without upstream payloads. */
const attempt = <A>(label: string, run: (signal: AbortSignal) => Promise<A>) =>
  Effect.tryPromise({ try: run, catch: () => new Error(label) });

/** Run one bounded client command and capture its machine-readable response. */
function command(client: string, args: string[], label: string) {
  return attempt(label, (signal) => new Promise<string>((resolve, reject) => {
    const child = spawn(client, args, { signal, stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    child.stdout!.on("data", (chunk: Buffer) => {
      output += chunk.toString();
      if (output.length > 1_048_576) { child.kill(); reject(new Error(label)); }
    });
    child.stderr!.resume();
    child.once("error", reject);
    child.once("close", (code) => code === 0 ? resolve(output) : reject(new Error(label)));
  })).pipe(Effect.timeoutFail({ duration: "30 seconds", onTimeout: () => new Error(`${label}: timed out`) }));
}

/** Require a usable resource graph from the connected session. */
function readSnapshot(client: string, socket: string) {
  return Effect.gen(function* () {
    const stdout = yield* command(client, ["--socket", socket, "--json", "session", "current", "snapshot"], "Session snapshot failed");
    const snapshot = yield* Effect.try(() => JSON.parse(stdout));
    if (!Array.isArray(snapshot.workspaces) || !Array.isArray(snapshot.terminals)) {
      return yield* Effect.fail(new Error("Private session returned an invalid snapshot"));
    }
  });
}

function connectArgs(
  endpoint: CmuxRemoteEndpoint,
  root: string,
  hubSocket: string,
  deviceName: string,
  socket: string,
  inviteFile?: string,
): string[] {
  const auth = inviteFile ? ["--invite-file", inviteFile] : endpoint.trustedCarrier ? ["--carrier"] : [];
  return [
    "remote", "connect", endpoint.route, ...auth,
    "--state-dir", path.join(root, "identity"),
    "--device-name", deviceName,
    "--headless", "--json", "--wireguard-hub", hubSocket,
    "--connect-timeout-seconds", "30", "--reconnect-attempts", "1",
    "--local-socket", socket,
  ];
}

/** Verify private enrollment and reconnect using exclusively probe-owned resources. */
function verify(image: string, client: string, requestedAuth: "trusted-carrier" | "client-grant") {
  return Effect.gen(function* () {
    const rawProbe = yield* command(client, ["remote-probe", "--json"], "Client probe failed");
    const probe = yield* Effect.try(() => JSON.parse(rawProbe));
    if (probe.app !== "cmux-tui" || !Array.isArray(probe.capabilities) || !probe.capabilities.includes("wireguard-hub")) {
      return yield* Effect.fail(new Error("This client lacks wireguard-hub. Update cmux NIGHTLY before diagnosing or replacing the Freestyle image."));
    }
    if (!process.env.FREESTYLE_API_KEY) return yield* Effect.fail(new Error("Set FREESTYLE_API_KEY"));
    const provider = new FreestyleProvider();
    const networking = provider.privateNetworking;
    const root = yield* Effect.acquireRelease(
      Effect.sync(() => mkdtempSync(path.join(tmpdir(), "cmux-image-link-"))),
      (directory) => Effect.sync(() => rmSync(directory, { recursive: true, force: true })),
    );
    const slug = `cmux-image-check-${randomUUID().slice(0, 12)}`;
    const network = yield* Effect.acquireRelease(
      attempt("Create diagnostic VPC failed", () => networking.ensureNetwork({ slug })),
      (value) => cleanup(`VPC ${value.id}`, () => networking.deleteNetwork(value.id)),
    );
    const vm = yield* Effect.acquireRelease(
      attempt("Create diagnostic VM failed", () => provider.create({
        image,
        network: { id: network.id },
        displayName: slug,
        providerMetadata: { cmuxRemoteAuth: requestedAuth },
      })),
      (value) => cleanup(`VM ${value.providerVmId}`, () => provider.destroy(value.providerVmId)),
    );
    const { privateKey, publicKey } = generateKeyPairSync("x25519");
    const clientPublicKey = publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64");
    const privateBytes = privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32).toString("base64");
    const { tunnel } = yield* Effect.acquireRelease(
      attempt("Create diagnostic tunnel failed", () => networking.createTunnel({ slug, networkId: network.id, clientPublicKey })),
      (value) => cleanup(`tunnel ${value.tunnel.id}`, () => networking.deleteTunnel(value.tunnel.id)),
    );
    if (!/^PrivateKey\s*=/m.test(tunnel.clientConfig)) {
      return yield* Effect.fail(new Error("Tunnel config has no private-key field"));
    }
    const config = tunnel.clientConfig.replace(/^PrivateKey\s*=.*$/m, `PrivateKey = ${privateBytes}`);
    const configPath = path.join(root, "wg.conf"), hubSocket = path.join(root, "wg.sock");
    yield* Effect.try(() => writeFileSync(configPath, config, { mode: 0o600 }));
    const hub = yield* startPrivateLinkClient(client, ["wg", "hub", "--config", configPath, "--socket", hubSocket], { event: "hub-ready", socket: hubSocket });
    yield* hub.ready;
    const endpoint = yield* attempt("Read image attach bundle failed", () => provider.openCmuxRemote(vm.providerVmId, {
      clientCapabilities: probe.capabilities,
      providerMetadata: vm.providerMetadata,
    }));
    const inviteFile = endpoint.invitation ? path.join(root, "invite") : undefined;
    if (endpoint.invitation && inviteFile) {
      yield* Effect.try(() => writeFileSync(inviteFile, `${endpoint.invitation!.uri}\n`, { mode: 0o600 }));
    }
    if (!endpoint.trustedCarrier && !endpoint.invitation) {
      return yield* Effect.fail(new Error("Fresh VM returned neither enrollment nor compatibility auth"));
    }
    let deviceFingerprint: string | undefined;
    yield* Effect.scoped(Effect.gen(function* () {
      const socket = path.join(root, "first.sock");
      const connection = yield* startPrivateLinkClient(
        client,
        connectArgs(endpoint, root, hubSocket, slug, socket, inviteFile),
        { event: "connection-snapshot", socket },
      );
      if (endpoint.invitation) {
        const approval = yield* attempt("Approve image enrollment failed", () =>
          provider.approveCmuxRemoteEnrollment(vm.providerVmId, endpoint.invitation!.invitationId));
        if (!approval.approved || !approval.deviceFingerprint) {
          return yield* Effect.fail(new Error("Image enrollment approval returned no device fingerprint"));
        }
        deviceFingerprint = approval.deviceFingerprint;
      }
      yield* connection.ready;
      yield* readSnapshot(client, socket);
    }));
    if (requestedAuth === "client-grant") {
      const socket = path.join(root, "carrier-negative.sock");
      const carrierEndpoint = { ...endpoint, invitation: undefined, trustedCarrier: true };
      const carrierAccepted = yield* Effect.scoped(Effect.gen(function* () {
        const connection = yield* startPrivateLinkClient(
          client,
          connectArgs(carrierEndpoint, root, hubSocket, `${slug}-carrier-negative`, socket),
          { event: "connection-snapshot", socket },
        );
        yield* connection.ready;
      })).pipe(
        Effect.timeoutFail({
          duration: "10 seconds",
          onTimeout: () => new Error("Carrier-negative probe did not finish"),
        }),
        Effect.either,
      );
      if (carrierAccepted._tag === "Right") {
        return yield* Effect.fail(new Error("Client-grant image still accepts carrier authentication"));
      }
    }
    const reconnectEndpoint = yield* attempt("Read enrolled attach bundle failed", () =>
      provider.openCmuxRemote(vm.providerVmId, {
        clientCapabilities: probe.capabilities,
        providerMetadata: vm.providerMetadata,
        ...(deviceFingerprint ? { deviceFingerprint } : {}),
      }));
    const socket = path.join(root, "reconnect.sock");
    const connection = yield* startPrivateLinkClient(
      client,
      connectArgs(reconnectEndpoint, root, hubSocket, slug, socket),
      { event: "connection-snapshot", socket },
    );
    yield* connection.ready;
    yield* readSnapshot(client, socket);
    console.log(JSON.stringify({ image, clientCommit: probe.build_identity,
      daemonCommit: endpoint.daemonBuild?.commit, trustedCarrier: endpoint.trustedCarrier,
      enrolled: deviceFingerprint !== undefined,
      carrierRejected: requestedAuth === "client-grant" ? true : undefined,
      reconnect: "passed", snapshot: "passed" }));
  });
}

const [image, client, mode] = process.argv.slice(2);
if (!image || !client || !/^sh-[a-zA-Z0-9]+$/.test(image) || (mode !== undefined && mode !== "--client-grant")) {
  console.error("Usage: bun scripts/verify-devbox-private-link.ts <snapshot-id> <cmux-tui-client> [--client-grant]");
  process.exit(1);
}
const controller = new AbortController();
const interrupt = () => controller.abort();
process.once("SIGINT", interrupt);
process.once("SIGTERM", interrupt);
try {
  await Effect.runPromise(Effect.scoped(verify(
    image,
    path.resolve(client),
    mode === "--client-grant" ? "client-grant" : "trusted-carrier",
  )), { signal: controller.signal });
} catch (error: unknown) {
  console.error(String(error));
  process.exitCode = 1;
} finally {
  process.off("SIGINT", interrupt);
  process.off("SIGTERM", interrupt);
}
