// A run-owned staging machine hosts the real chat and its staging-configured owner.
import { randomBytes } from "node:crypto";
import { constants, accessSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { ClientDial, type DialLike } from "./cloud-chaos.ts";
import { stagingLink } from "./share-two-accounts-guest.ts";
import { Api, CHAT_START_SIZE, http, listAllMachines, resolveBackend, waitMachine } from "./cloud-journey.ts";

const wire = new URL("./share-two-accounts-wire.py", import.meta.url);
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
  return { api, name: "two-account " + tag, local: join(process.env.RUNNER_TEMP, tag + "-carrier") };
}

async function installToken(api: Api, tag: string, name: string, user: string) {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const { x, y } = await crypto.subtle.exportKey("jwk", keys.publicKey);
  const install = await api.op("install.register", {
    public_jwk: { kty: "EC", crv: "P-256", x, y }, name, device_name: "Chat sharing proof", kind: "cli", platform: "linux",
  }, tag + "-install");
  const who = { user: install.user ?? user, install: install.id };
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

function response(raw: any, operation: string) {
  if (raw?.ok !== true) throw new OwnerError(operation + ": " + codeOf(raw?.error_code ?? raw?.error?.code));
  const data = raw.data ?? raw.result;
  if (data?.refused) throw new OwnerError(operation + ": " + codeOf(data.refused));
  return data;
}

// MachineGuest.exec runs as the uid-1000 work user from their own HOME. Its stdin is
// separate from the command and output capture. Only a static error code may leave it.
export async function machineExec(api: Pick<Api, "raw">, machine: string, command: string, input: string, timeoutMs: number) {
  const r = await api.raw("POST", "/v1/cloud/machines/" + machine + "/exec", {
    command, stdinBase64: Buffer.from(input).toString("base64"), timeoutMs,
  }, timeoutMs + 15_000);
  if (r.status !== 200 || r.body?.ok === false)
    throw new OwnerError("Staging work-user exec returned HTTP " + r.status);
  const value = r.body;
  let receipt;
  try { receipt = JSON.parse(value.stdout); } catch { throw new OwnerError("Staging work-user exec returned no receipt"); }
  if (value.exitCode !== 0 || receipt.error)
    throw new OwnerError("Staging work-user exec: " + codeOf(receipt.error));
  return receipt;
}

type Action = { operation: "prompt" | "wait_guest"; surface: number; text: string } | { operation: "revoke"; share_id: string };

// A measured shell-run contains only a synthetic chat marker or a room id. The runner
// timestamps the send on the warm carrier; the long-poll receives the matching owner event.
export async function measured(dial: Pick<DialLike, "request">, remote: string, action: Action) {
  const data = Buffer.from(JSON.stringify(action)).toString("base64");
  const command = "printf %s " + data + " | base64 -d | python3 -I " + remote + "/wire.py";
  const sent = performance.now();
  const run = response(await dial.request({ cmd: "shell-run", command, cwd: remote }, 8000), "Start owner " + action.operation).run;
  if (!run) throw new OwnerError("Owner request returned no run");
  const deadline = sent + 35_000;
  let after = 0, output = "";
  while (performance.now() < deadline) {
    const read = response(await dial.request({ cmd: "shell-read", run, after, wait_ms: 5000 }, 8000), "Read owner " + action.operation);
    const observed = performance.now();
    output += read.output;
    if (read.truncated || output.length > 512) throw new OwnerError("Unexpected owner command output");
    if (output.includes("\n") || read.exit) {
      let receipt;
      try { receipt = JSON.parse(output); } catch { throw new OwnerError("Owner " + action.operation + " ended without a receipt"); }
      if (receipt.ok !== true) throw new OwnerError("Owner " + action.operation + ": " + codeOf(receipt.error));
      return { sent, observed };
    }
    after = read.next;
  }
  throw new OwnerError("Timed out waiting for owner " + action.operation);
}

export async function openOwner({ stackToken, tag, cmux }: { stackToken: string; tag: string; cmux: string }) {
  const { api, name, local } = staging(stackToken, tag);
  const machine = await step("Create owner's disposable staging machine", async () => {
    const result = await api.op("cloud.machine.create", { name, size: CHAT_START_SIZE }, tag + "-create");
    if (!result?.machine?.id) throw new OwnerError("Staging create returned no machine");
    return result.machine.id as string;
  });
  // An always() step also recovers a machine or install whose creation lost its response.
  const row = await step("Wait for owner's staging machine", () => waitMachine(api, machine, m => m.status === "running" && !!m.host, 300_000));
  if (typeof row.creator !== "string" || !row.creator) throw new OwnerError("Staging machine returned no creator");
  const install = await step("Register temporary staging owner install", () => installToken(api, tag, name, row.creator));
  const remote = "/tmp/" + tag;
  // A separate uid-1000 owner uses the real image binary and existing acpmux. Only this
  // process selects the staging room; the machine's managed session host stays on its configuration.
  await step("Start isolated staging owner", () => machineExec(api, machine, [
    "set -eu", "umask 077", "mkdir -m 700 " + remote,
    "cat > " + remote + "/wire.py", "exec python3 -I " + remote + "/wire.py setup",
  ].join("\n"), readFileSync(wire, "utf8"), 35_000));
  accessSync(cmux, constants.X_OK);
  mkdirSync(local, { mode: 0o700 });
  let connected!: () => void;
  const ready = new Promise<void>(resolve => { connected = resolve; });
  const dial = new ClientDial({
    cmux, machine,
    env: { PATH: process.env.PATH, HOME: local, CMUX_TUI_STATE_DIR: local, CMUX_CLOUD_API_URL: ORIGIN, CMUX_CLOUD_ACCESS_TOKEN: stackToken },
  }, () => {}, connected);
  try {
    dial.start();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([ready, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new OwnerError("Owner carrier did not connect within 90 seconds")), 90_000); })]);
    } finally { clearTimeout(timer); }
    const pad = randomBytes(1024);
    const share = await step("Start real owner chat and create a staging Talk link", () => machineExec(api, machine,
      "exec python3 -I " + remote + "/wire.py", JSON.stringify({
        operation: "open", token: install.token, link_pad: pad.toString("base64"),
      }), 155_000));
    const link = Buffer.from(share.sealed_link ?? "", "base64");
    if (!link.length || link.length > pad.length || !Number.isSafeInteger(share.surface))
      throw new OwnerError("Missing private staging chat or link");
    for (let i = 0; i < link.length; i++) link[i] ^= pad[i];
    const url = stagingLink(link.toString("utf8"));
    if (url.pathname !== "/g/" + share.share_id) throw new OwnerError("Staging daemon returned a link for a different share");
    let revokeRequested = false;
    const revoke = () => step("Revoke Talk link", async () => {
      revokeRequested = true;
      return (await measured(dial, remote, { operation: "revoke", share_id: share.share_id })).sent;
    });
    return {
      url: url.href,
      prompt: (text: string) => step("Send owner prompt", async () => (await measured(dial, remote, { operation: "prompt", surface: share.surface, text })).sent),
      waitGuest: (text: string) => step("Receive the held Talk message", async () => (await measured(dial, remote, { operation: "wait_guest", surface: share.surface, text })).observed),
      revoke,
      close: async () => {
        try { if (!revokeRequested) await revoke(); }
        finally {
          dial.stop();
          try { await clean(api, tag, [machine], [install.id]); }
          finally { rmSync(local, { force: true, recursive: true }); }
        }
      },
    };
  } catch (error) { dial.stop(); throw error; }
}
