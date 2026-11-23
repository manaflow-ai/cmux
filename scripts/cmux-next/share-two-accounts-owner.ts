// The owner uses the normal signed Native carrier to a run-owned staging Cloud machine.
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { constants, accessSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { ChatClient, ClientDial, type DialLike } from "./cloud-chaos.ts";
import { stagingLink } from "./share-two-accounts-guest.ts";
import { Api, CHAT_START_SIZE, http, listAllMachines, resolveBackend, waitMachine } from "./cloud-journey.ts";

const ROOMS = ["https://share-staging.cmux.dev", "https://cmux-platform-staging.debussy.workers.dev"];
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

type NativeContext = ConstructorParameters<typeof ClientDial>[0] & { tag: string };
type MakeDial = (onLine: (msg: any) => void, onDial: () => void) => DialLike;

export async function openNativeChat(ctx: NativeContext, ownerToken: string,
  makeDial: MakeDial = (line, connected) => new ClientDial(ctx, line, connected), guestTimeoutMs = 20_000) {
  const records = new EventEmitter();
  const chat = new ChatClient(ctx, (onLine, onDial) => makeDial(msg => {
    // Arrival time is the job clock, on the owner's attached surface.
    if (msg?.event === "agent-session-record" && msg.surface === chat.surface)
      records.emit("record", msg.record, performance.now());
    onLine(msg);
  }, onDial));
  const request = async (cmd: string, fields: Record<string, unknown> = {}) =>
    response(await chat.dial.request({ cmd, ...fields }, 30_000), cmd);
  try {
    // The staging Cloud matrix's OpenCode Zen chat starts without a provider login.
    await step("Open and attach staging owner chat", () => chat.open("opencode"));
    const config = await request("agent-session-share-room");
    if (!ROOMS.includes(config?.room) || config.owner_api !== ORIGIN)
      throw new OwnerError("The Cloud machine's daemon did not report the staging share room and staging owner API");
    const share = await request("agent-session-share-create", {
      session: chat.session, surface: chat.surface, role: "talk", signed_in_role: "talk",
      ttl_secs: 900, owner_token: ownerToken,
    });
    const url = stagingLink(share?.url);
    if (typeof share.share_id !== "string" || url.pathname !== "/g/" + share.share_id)
      throw new OwnerError("Staging daemon returned a link for a different share");
    return {
      url: url.href,
      prompt: (text: string) => step("Send owner prompt", async () => {
        const sent = performance.now();
        await request("agent-session-prompt", { surface: chat.surface, text, prompt_id: randomUUID() });
        return sent;
      }),
      waitGuest(text: string): Promise<number> {
        return new Promise((resolve, reject) => {
          const match = (record: any, received: number) => {
            const msg = record?.msg;
            if (record?.kind !== "queued" || msg?.awaitingOwner !== true ||
                !String(msg.promptId).startsWith("g-") || msg.text !== text) return;
            clearTimeout(timer);
            records.off("record", match);
            resolve(received);
          };
          const timer = setTimeout(() => {
            records.off("record", match);
            reject(new OwnerError("Owner chat did not receive the held Talk message within " + guestTimeoutMs + " ms"));
          }, guestTimeoutMs);
          records.on("record", match);
        });
      },
      revoke: () => step("Revoke Talk link", async () => {
        const sent = performance.now();
        await request("agent-session-share-revoke", { share_id: share.share_id });
        return sent;
      }),
      close: () => chat.stop(),
    };
  } catch (error) {
    chat.stop();
    throw error;
  }
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
  const chat = await step("Connect owner and share staging chat", async () => {
    accessSync(cmux, constants.X_OK);
    mkdirSync(local, { mode: 0o700 });
    return openNativeChat({
      cmux, machine, tag,
      env: { PATH: process.env.PATH, HOME: local, CMUX_TUI_STATE_DIR: local, CMUX_CLOUD_API_URL: ORIGIN, CMUX_CLOUD_ACCESS_TOKEN: stackToken },
    }, install.token);
  });
  return {
    ...chat,
    close: async () => {
      chat.close();
      try { await clean(api, tag, [machine], [install.id]); }
      finally { rmSync(local, { force: true, recursive: true }); }
    },
  };
}
