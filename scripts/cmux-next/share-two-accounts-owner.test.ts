import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cleanupOwnerMachine, openNativeChat } from "./share-two-accounts-owner.ts";

const room = "https://share-staging.cmux.dev";
const origin = "https://cloud-api-staging.cmux.dev";
const shareId = "fake-room-id";
const url = room + "/g/" + shareId + "#synthetic-secret";
const token = "synthetic-owner-token";

function fixture(config: unknown = { room, owner_api: origin }) {
  const frames: Record<string, any>[] = [];
  let push!: (msg: unknown) => void;
  let stopped = false;
  const replies: Record<string, unknown> = {
    identify: { registry_id: "here" },
    "create-workspace": { workspace: 9 }, "new-conversation-tab": { surface: 8 },
    "agent-session-start": { session: "session" }, "agent-session-attach": { events: [] },
    "agent-session-share-room": config, "agent-session-share-create": { share_id: shareId, url },
    "agent-session-prompt": {}, "agent-session-share-revoke": {},
  };
  const open = () => openNativeChat({ tag: "share-999-1", cmux: "unused", machine: "machine", env: {} }, token, (line, ready) => {
    push = line;
    return {
      dials: 1, start: ready, stop: () => { stopped = true; },
      request: async frame => {
        frames.push(frame);
        if (!(String(frame.cmd) in replies)) throw new Error("Unexpected frame " + frame.cmd);
        return { ok: true, data: replies[String(frame.cmd)] };
      },
    };
  }, 45);
  return { open, frames, push: (msg: unknown) => push(msg), stopped: () => stopped };
}

test("the native owner starts and attaches one chat, creates a staging Talk link, and sends prompts and revoke directly", async () => {
  const f = fixture();
  const owner = await f.open();
  try {
    expect(owner.url).toBe(url);
    expect(f.frames.map(x => x.cmd)).toEqual(["identify", "create-workspace", "new-conversation-tab",
      "agent-session-start", "agent-session-attach", "agent-session-share-room", "agent-session-share-create"]);
    expect(f.frames[3]).toMatchObject({ surface: 8, vm_kind: "owner", harness: "opencode" });
    expect(f.frames.at(-1)).toMatchObject({ surface: 8, session: "session", owner_token: token, role: "talk", signed_in_role: "talk" });
    expect(JSON.stringify(f.frames.slice(0, -1))).not.toContain(token);
    const before = performance.now();
    expect(await owner.prompt("marker")).toBeGreaterThanOrEqual(before);
    expect(await owner.revoke()).toBeLessThanOrEqual(performance.now());
    expect(f.frames.at(-2)).toMatchObject({ cmd: "agent-session-prompt", surface: 8, text: "marker" });
    expect(f.frames.at(-1)).toMatchObject({ cmd: "agent-session-share-revoke", share_id: shareId });
  } finally { owner.close(); }
  expect(f.stopped()).toBe(true);
});

test("missing or mismatched staging room stops the dial before any share token leaves the runner", async () => {
  for (const config of [{ room: null }, { room, owner_api: "https://cloud-api.cmux.dev" }, { room: "https://share.cmux.dev", owner_api: origin }]) {
    const f = fixture(config);
    await expect(f.open()).rejects.toThrow("did not report the staging share room and staging owner API");
    expect(JSON.stringify(f.frames)).not.toContain(token);
    expect(f.stopped()).toBe(true);
  }
});

test("owner delivery requires a guest's held queue record with the exact marker on the attached surface", async () => {
  const f = fixture(), owner = await f.open();
  const msg = { promptId: "g-1", text: "guest words", awaitingOwner: true };
  const event = (surface: number, fields: typeof msg) => f.push({
    event: "agent-session-record", surface, record: { kind: "queued", seq: 3, msg: fields },
  });
  try {
    const none = owner.waitGuest(msg.text);
    event(9, msg);
    event(8, { ...msg, promptId: "owner-1" });
    event(8, { ...msg, awaitingOwner: false });
    event(8, { ...msg, text: "guest words 2" });
    await expect(none).rejects.toThrow("did not receive the held Talk message within 45 ms");
    const matched = owner.waitGuest(msg.text);
    const started = performance.now();
    event(8, msg);
    expect(await matched).toBeGreaterThanOrEqual(started);
  } finally { owner.close(); }
});

test("cleanup checks every machine page, confirms deletion and revocation, and scopes both to the exact run attempt", async () => {
  const root = mkdtempSync(join(tmpdir(), "share-clean-")), priorRoot = process.env.RUNNER_TEMP;
  const fetchBefore = globalThis.fetch, seen: string[] = [];
  process.env.RUNNER_TEMP = root;
  const tag = "share-56789-1", name = "two-account " + tag;
  let removed = false;
  globalThis.fetch = (async (url, init) => {
    expect(new URL(String(url)).origin).toBe("https://cloud-api-staging.cmux.dev");
    const { op, params } = JSON.parse(init!.body as string);
    seen.push(op);
    let value;
    if (op === "cloud.machine.list") {
      value = params.cursor ? { machines: removed ? [] : [{ name, id: "owned" }] } :
        { machines: [{ name: name + "0", id: "other" }], next_cursor: "page-2" };
    } else if (op === "install.list") {
      value = { installs: [{ name, kind: "cli", id: "run-install", revoked_at: removed ? 30 : null }, { name: name + "0", kind: "cli", id: "other" }] };
    } else if (op === "cloud.machine.delete") {
      expect(params.machine).toBe("owned"); value = { deleted: true };
    } else if (op === "cloud.machine.get") {
      expect(params.machine).toBe("owned"); value = { status: "deleted" }; removed = true;
    } else if (op === "install.revoke") {
      expect(params.install).toBe("run-install"); value = { id: "run-install", revoked_at: 30 };
    } else throw new Error("unexpected API");
    return Response.json({ ok: true, value });
  }) as typeof fetch;
  try {
    await cleanupOwnerMachine("synthetic", tag);
    await cleanupOwnerMachine("synthetic", tag);
    expect(seen.filter(op => op === "cloud.machine.delete").length).toBe(1);
    expect(seen.filter(op => op === "cloud.machine.get").length).toBe(1);
    expect(seen.filter(op => op === "install.revoke").length).toBe(1);
  } finally {
    globalThis.fetch = fetchBefore;
    if (priorRoot === undefined) delete process.env.RUNNER_TEMP; else process.env.RUNNER_TEMP = priorRoot;
    rmSync(root, { force: true, recursive: true });
  }
});
