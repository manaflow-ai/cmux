// Staging owner for the two-account flow. A disposable Cloud machine hosts one chat and the
// production share bridge. Its private test daemon explicitly names staging as its room.
import { randomBytes } from "node:crypto";
import { constants, accessSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { ClientDial } from "./cloud-chaos.ts";
import { Api, CHAT_START_SIZE, http, listAllMachines, resolveBackend, waitMachine } from "./cloud-journey.ts";

const ROOM = "https://share-staging.cmux.dev";
const ORIGIN = resolveBackend("staging").api;

// Cloud/journal errors can include request bodies or raw terminal output. Only our own fixed
// step names and the daemon's structured refusal codes are eligible for the artifact.
class OwnerError extends Error {}
function codeOf(value: unknown) {
  return typeof value === "string" && /^[a-z][a-z0-9_.]{1,75}$/.test(value) ? value : "refused";
}
async function step<T>(name: string, fn: () => Promise<T>): Promise<T> {
  try { return await fn(); }
  catch (e) {
    if (e instanceof OwnerError) throw e;
    throw new OwnerError(name + " failed");
  }
}
function staging(stackToken: string, tag: string) {
  if (!/^share-[0-9]{1,24}-[0-9]{1,12}$/.test(tag) || !stackToken || !process.env.RUNNER_TEMP)
    throw new OwnerError("Missing owner sign-in, Actions run identity, or runner temp directory");
  const api = new Api(ORIGIN);
  api.bearer = stackToken;
  return { api, name: "two-account " + tag, local: join(process.env.RUNNER_TEMP, tag + "-carrier"), remote: "/tmp/" + tag };
}

async function installToken(api: Api, tag: string, name: string, user: string) {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const { x, y } = await crypto.subtle.exportKey("jwk", keys.publicKey);
  const install = await api.op("install.register", {
    public_jwk: { kty: "EC", crv: "P-256", x, y }, name, device_name: "Chat sharing proof", kind: "cli", platform: "linux",
  }, tag + "-install");
  const who = { user, install: install.id };
  const challenge = await http("POST", ORIGIN + "/v1/auth/challenge", who, {});
  if (challenge.status !== 200) throw new OwnerError("Owner install challenge returned HTTP " + challenge.status);
  const { message_prefix, nonce } = challenge.body;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys.privateKey, new TextEncoder().encode(message_prefix + nonce));
  const token = await http("POST", ORIGIN + "/v1/auth/token", { ...who, nonce, signature: Buffer.from(signature).toString("base64url") }, {});
  if (token.status !== 200 || typeof token.body?.access_token !== "string")
    throw new OwnerError("Owner install token exchange returned HTTP " + token.status);
  return { id: install.id as string, token: token.body.access_token as string };
}

async function clean(api: Api, tag: string, machines: string[], installs: string[]) {
  const actions = [
    ...machines.map(async id => {
      const result = await api.deleteMachine(id, tag + "-delete-" + id);
      if (result?.deleted !== true) throw new OwnerError("Missing machine deletion receipt");
      await waitMachine(api, id, row => row.status === "deleted", 90_000, true);
    }),
    ...installs.map(async id => {
      const result = await api.op("install.revoke", { install: id }, tag + "-revoke-" + id);
      if (result?.id !== id || typeof result.revoked_at !== "number")
        throw new OwnerError("Missing temporary install revocation receipt");
    }),
  ];
  const outcomes = await Promise.allSettled(actions);
  if (outcomes.some(outcome => outcome.status === "rejected"))
    throw new OwnerError("Could not delete this run's staging machine or revoke its temporary owner install");
}

// The always() recovery uses the same run/attempt name even if the create response was lost.
export async function cleanupOwnerMachine(stackToken: string, tag: string) {
  const { api, name, local } = staging(stackToken, tag);
  try {
    const [machines, installs] = await Promise.allSettled([
      listAllMachines(params => api.read("cloud.machine.list", params)), api.read("install.list", {}),
    ]);
    const ownedMachines = machines.status === "fulfilled" ? machines.value.filter(m => m.name === name && m.status !== "deleted").map(m => m.id) : [];
    const ownedInstalls = installs.status === "fulfilled" ? installs.value.installs.filter(
      (i: any) => i.name === name && i.kind === "cli" && i.revoked_at == null,
    ).map((i: any) => i.id) : [];
    await clean(api, tag, ownedMachines, ownedInstalls);
    if (machines.status === "rejected" || installs.status === "rejected")
      throw new OwnerError("Could not check both run-owned resources during cleanup");
  } finally { rmSync(local, { force: true, recursive: true }); }
}

// MachineGuest's work-user /exec accepts setup secrets on a separate stdin. Neither the
// install credential nor the returned link enters a shell command, a file, or a shell-run.
async function machineExec(api: Api, machine: string, command: string, input: string, timeoutMs: number) {
  const r = await api.raw("POST", "/v1/cloud/machines/" + machine + "/exec", {
    command, stdinBase64: Buffer.from(input).toString("base64"), timeoutMs,
  }, timeoutMs + 15_000);
  if (r.status !== 200 || r.body?.ok === false)
    throw new OwnerError("Staging machine exec returned HTTP " + r.status);
  const value = r.body.value ?? r.body;
  return { output: String(value.stdout ?? ""), code: value.exitCode ?? value.exit_code };
}

function response(raw: any, operation: string) {
  if (raw?.ok !== true) throw new OwnerError(operation + ": " + codeOf(raw?.error_code ?? raw?.error?.code));
  const data = raw.data ?? raw.result;
  if (data?.refused) throw new OwnerError(operation + ": " + codeOf(data.refused));
  return data;
}

const wireProgram = new URL("./share-two-accounts-wire.py", import.meta.url);
type WireRequest = { operation: "prompt" | "wait_guest"; surface: number; text: string } | { operation: "revoke"; share_id: string };

// The runner sends only synthetic chat markers and a public room id through the owner's
// already-connected carrier. shell-read long-polls that same carrier for the socket client's receipt.
async function measured(dial: ClientDial, remote: string, request: WireRequest) {
  const data = Buffer.from(JSON.stringify(request)).toString("base64");
  const command = "printf %s " + data + " | base64 -d | python3 -I " + remote + "/wire.py";
  const sent = performance.now();
  const run = response(await dial.request({ cmd: "shell-run", command }, 10_000), "Start owner " + request.operation).run;
  if (!run) throw new OwnerError("Owner command returned no run");
  let after = 0, output = "";
  const deadline = sent + 32_000;
  while (performance.now() < deadline) {
    const read = response(await dial.request({ cmd: "shell-read", run, after, wait_ms: 5000 }, 8000), "Read owner " + request.operation);
    const observed = performance.now();
    output += read.output;
    if (read.truncated || output.length > 1024) throw new OwnerError("Unexpected owner command output");
    if (output.includes("\n") || read.exit) {
      let value;
      try { value = JSON.parse(output); } catch { throw new OwnerError("Owner " + request.operation + " ended without a receipt"); }
      if (value.ok !== true) throw new OwnerError("Owner " + request.operation + ": " + codeOf(value.error));
      return { sent, observed };
    }
    after = read.next;
  }
  throw new OwnerError("Timed out waiting for owner " + request.operation);
}

export async function openOwner({ stackToken, tag, cmux }: { stackToken: string; tag: string; cmux: string }) {
  const { api, name, local, remote } = staging(stackToken, tag);
  const machine = await step("Create owner's disposable staging machine", async () => {
    const result = await api.op("cloud.machine.create", { name, size: CHAT_START_SIZE }, tag + "-create");
    if (!result?.machine?.id) throw new OwnerError("Staging create returned no machine");
    return result.machine.id as string;
  });
  let dial: ClientDial | undefined;
  try {
    const machineRow = await step("Wait for owner's staging machine", () => waitMachine(api, machine, m => m.status === "running" && !!m.host, 300_000));
    if (typeof machineRow.creator !== "string" || !machineRow.creator) throw new OwnerError("Staging machine returned no creator");
    const install = await step("Register temporary staging owner install", () => installToken(api, tag, name, machineRow.creator));
    await step("Start staging sharing daemon", async () => {
      const command = [
        "set -eu", "umask 077", "mkdir -m 700 " + remote, "cat > " + remote + "/wire.py",
        'bin="$HOME/.cmux/bin/cmux-tui"; [ -x "$bin" ] || bin="$(command -v cmux-tui)"',
        'for sock in "$HOME/.cmux/acpmux/acpmux.sock" "$HOME/.acpmux/acpmux.sock"; do if [ -S "$sock" ]; then export ACPMUX_SOCKET="$sock"; break; fi; done',
        "CMUX_SHARE_ROOM_URL=" + ROOM + " CMUX_TUI_STATE_DIR=" + remote + '/state nohup "$bin" --headless --socket ' + remote + "/owner.sock </dev/null >/dev/null 2>&1 &",
        "for i in $(seq 1 100); do [ ! -S " + remote + "/owner.sock ] || exit 0; sleep 0.1; done", "exit 1",
      ].join("\n");
      const r = await machineExec(api, machine, command, readFileSync(wireProgram, "utf8"), 35_000);
      if (r.code !== 0) throw new OwnerError("Dedicated staging share daemon did not open its socket");
    });
    const share = await step("Start owner chat and create staging Talk link", async () => {
      // Machine exec providers retain stdout on the guest disk. A fresh private-stdin pad
      // keeps the bearer link out of that output, including during a cancelled run.
      const pad = randomBytes(1024);
      const r = await machineExec(api, machine, "python3 -I " + remote + "/wire.py", JSON.stringify({
        operation: "open", token: install.token, link_pad: pad.toString("base64"),
      }), 155_000);
      let share;
      try { share = JSON.parse(r.output); } catch { throw new OwnerError("Owner chat start or share creation ended without a receipt"); }
      if (r.code !== 0 || share.error) throw new OwnerError("Start owner chat and create Talk link: " + codeOf(share.error));
      const encrypted = Buffer.from(share.sealed_link ?? "", "base64");
      if (!encrypted.length || encrypted.length > pad.length) throw new OwnerError("Missing protected staging link");
      for (let i = 0; i < encrypted.length; i++) encrypted[i] ^= pad[i];
      const url = encrypted.toString("utf8");
      if (typeof share.share_id !== "string" || !Number.isSafeInteger(share.surface) || new URL(url).origin !== ROOM)
        throw new OwnerError("Owner daemon did not return a hosted staging share");
      return { url, share_id: share.share_id as string, surface: share.surface as number };
    });
    const carrier = await step("Connect owner's staging carrier", async () => {
      accessSync(cmux, constants.X_OK);
      mkdirSync(local, { mode: 0o700 });
      let ready!: () => void;
      const connected = new Promise<void>(resolve => { ready = resolve; });
      dial = new ClientDial({
        cmux, machine, env: { PATH: process.env.PATH, HOME: local, CMUX_TUI_STATE_DIR: local, CMUX_CLOUD_API_URL: ORIGIN, CMUX_CLOUD_ACCESS_TOKEN: stackToken },
      }, () => {}, ready);
      dial.start();
      let timer;
      try {
        await Promise.race([connected, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new OwnerError("Owner carrier did not connect within 90 seconds")), 90_000); })]);
      } finally { clearTimeout(timer); }
      return dial;
    });
    return {
      url: share.url,
      prompt: (text: string) => step("Send owner prompt", async () => (await measured(carrier, remote, { operation: "prompt", surface: share.surface, text })).sent),
      waitGuest: (text: string) => step("Receive held Talk message", async () => (await measured(carrier, remote, { operation: "wait_guest", surface: share.surface, text })).observed),
      revoke: () => step("Revoke Talk link", async () => (await measured(carrier, remote, { operation: "revoke", share_id: share.share_id })).sent),
      close: async () => {
        carrier.stop();
        try { await clean(api, tag, [machine], [install.id]); }
        finally { rmSync(local, { force: true, recursive: true }); }
      },
    };
  } catch (error) {
    dial?.stop();
    // The workflow's always() step also recovers an install or VM whose creation lost its response.
    throw error;
  }
}
