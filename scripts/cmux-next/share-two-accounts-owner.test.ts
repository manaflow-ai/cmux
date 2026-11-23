import { expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { connect, createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cleanupOwnerMachine, machineExec, measured } from "./share-two-accounts-owner.ts";

type Frame = Record<string, any>;
const room = "https://share-staging.cmux.dev";
const issuer = "https://cloud-api-staging.cmux.dev";
const script = new URL("./share-two-accounts-wire.py", import.meta.url);

test("the work-user setup starts an isolated staging owner using the existing machine acpmux socket", async () => {
  const root = mkdtempSync(join(tmpdir(), "share-start-")), home = join(root, "home"), remote = join(root, "share-7-1");
  const acp = join(home, ".acpmux/acpmux.sock"), binary = join(home, ".cmux/bin/cmux-tui");
  mkdirSync(join(home, ".acpmux"), { recursive: true });
  mkdirSync(join(home, ".cmux/bin"), { recursive: true });
  mkdirSync(remote);
  copyFileSync(script, join(remote, "wire.py"));
  const acpmux = createServer();
  // The test binary lives in this fixture. It exits when we connect, or in five seconds.
  writeFileSync(binary, `#!/usr/bin/env python3
import json, os, pathlib, socket, sys
sock = pathlib.Path(sys.argv[-1])
env = os.environ
(sock.parent / "startup.json").write_text(json.dumps([sys.argv[1:], os.getcwd(), env["HOME"], env["ACPMUX_SOCKET"], env["CMUX_TUI_STATE_DIR"], env["CMUX_SHARE_ROOM_URL"]]))
with socket.socket(socket.AF_UNIX) as s:
    s.bind(str(sock))
    s.listen(1)
    s.settimeout(5)
    with s.accept()[0]: pass
`, { mode: 0o700 });
  try {
    await new Promise<void>((res, rej) => acpmux.once("error", rej).listen(acp, res));
    const child = Bun.spawn(["python3", "-I", join(remote, "wire.py"), "setup"], {
      cwd: home, env: { HOME: home, PATH: process.env.PATH }, stdout: "pipe", stderr: "pipe",
    });
    const out = await new Response(child.stdout).json();
    // CI and the lane run as a work user. A root test runner must exercise the refusal.
    if (process.getuid?.() === 0) {
      expect(out.error).toBe("expected_work_user_in_own_home");
      expect(await child.exited).toBe(1);
      return;
    }
    expect(out.ok).toBe(true);
    expect(await child.exited).toBe(0);
    const ownerSock = join(remote, "owner.sock");
    expect(JSON.parse(readFileSync(join(remote, "startup.json"), "utf8"))).toEqual([
      ["--headless", "--session", "share-7-1", "--socket", ownerSock], home, remote, acp, join(remote, "state"), room,
    ]);
    await new Promise<void>((res, rej) => { const s = connect(ownerSock, () => { s.end(); res(); }); s.once("error", rej); });
  } finally { acpmux.close(); rmSync(root, { recursive: true, force: true }); }
});

async function machine(request: Frame, reply: (frame: Frame, push: (value: Frame) => void) => Frame, expire = false) {
  const dir = mkdtempSync(join(tmpdir(), "share-rpc-"));
  copyFileSync(script, join(dir, "wire.py"));
  let child: ReturnType<typeof Bun.spawn> | undefined, peer: Socket | undefined;
  const server = createServer(sock => {
    peer = sock;
    let buffered = "";
    const push = (frame: Frame) => sock.write(JSON.stringify(frame) + "\n");
    sock.on("data", data => {
      buffered += data;
      for (let i = buffered.indexOf("\n"); i >= 0; i = buffered.indexOf("\n")) {
        const frame = JSON.parse(buffered.slice(0, i));
        buffered = buffered.slice(i + 1);
        push({ ok: true, id: frame.id, data: reply(frame, push) });
        if (expire) child!.kill("SIGALRM");
      }
    });
    sock.on("error", () => {});
  });
  try {
    await new Promise<void>((res, rej) => server.once("error", rej).listen(join(dir, "owner.sock"), res));
    const running = Bun.spawn(["python3", "-I", join(dir, "wire.py")], {
      stdin: new Blob([JSON.stringify(request)]), stdout: "pipe", stderr: "pipe",
    });
    child = running;
    const stdout = await new Response(running.stdout).text();
    return { result: JSON.parse(stdout), stdout, code: await running.exited };
  } finally {
    peer?.destroy(); server.close(); child?.kill(); rmSync(dir, { recursive: true, force: true });
  }
}

test("the MachineGuest exec sends private stdin separately and exposes only explicit receipt codes", async () => {
  const { Api } = await import("./cloud-journey.ts");
  const api = new Api(issuer), original = globalThis.fetch;
  const secret = "synthetic-private-input", cmd = "exec python3 -I /tmp/share-7-1/wire.py";
  let reply = { exitCode: 0, stdout: '{"ok":true}', stderr: "" };
  globalThis.fetch = (async (url, init) => {
    expect(String(url)).toBe(issuer + "/v1/cloud/machines/owned/exec");
    expect(JSON.parse(init!.body as string)).toEqual({
      command: cmd, stdinBase64: Buffer.from(secret).toString("base64"), timeoutMs: 155000,
    });
    return Response.json(reply);
  }) as typeof fetch;
  try {
    expect(await machineExec(api, "owned", cmd, secret, 155000)).toEqual({ ok: true });
    reply = { exitCode: 1, stdout: '{"error":"share.room_refused"}', stderr: secret };
    await expect(machineExec(api, "owned", cmd, secret, 155000)).rejects.toThrow(/^Staging work-user exec: share\.room_refused$/);
    reply = { exitCode: 1, stdout: secret, stderr: secret };
    await expect(machineExec(api, "owned", cmd, secret, 155000)).rejects.toThrow(/^Staging work-user exec returned no receipt$/);
  } finally { globalThis.fetch = original; }
});

test("room and issuer are checked before a Talk link is created for the started chat; the link is concealed in exec output", async () => {
  const token = "synthetic-owner-token", url = room + "/g/synthetic-room#synthetic-secret", pad = randomBytes(1024);
  const request = { operation: "open", token, link_pad: pad.toString("base64") };
  const replies: Frame = {
    "agent-session-share-room": { room, owner_api: issuer }, "identify": { registry_id: "here" },
    "create-workspace": { workspace: 9 }, "new-conversation-tab": { surface: 8 },
    "agent-session-start": { session: "session" }, "agent-session-share-create": { share_id: "synthetic-room", url },
  };
  const frames: Frame[] = [];
  const out = await machine(request, f => { frames.push(f); return replies[f.cmd]; });
  expect(out.code).toBe(0);
  expect(frames.at(-2)).toMatchObject({ cmd: "agent-session-start", surface: 8, vm_kind: "owner" });
  expect(frames.at(-1)).toMatchObject({ cmd: "agent-session-share-create", session: "session", surface: 8, signed_in_role: "talk", owner_token: token });
  expect(JSON.stringify(frames.slice(0, -1))).not.toContain(token);
  expect(out.stdout).not.toContain(token);
  expect(out.stdout).not.toContain("synthetic-secret");
  const clear = Buffer.from(out.result.sealed_link, "base64");
  for (let i = 0; i < clear.length; i++) clear[i] ^= pad[i];
  expect(clear.toString()).toBe(url);
  const wrong = await machine(request, f => {
    expect(f.cmd).toBe("agent-session-share-room"); return { room, owner_api: "https://cloud-api.cmux.dev" };
  });
  expect(wrong.result.error).toBe("private_owner_did_not_select_staging_room_and_issuer");
  expect(wrong.code).toBe(1);
});

test("owner prompts attach to their surface; the owner revokes the same share", async () => {
  const frames: Frame[] = [];
  const trace = (frame: Frame) => { frames.push(frame); return {}; };
  expect((await machine({ operation: "prompt", surface: 7, text: "marker" }, trace)).code).toBe(0);
  expect((await machine({ operation: "revoke", share_id: "room-7" }, trace)).code).toBe(0);
  expect(frames.map(f => f.cmd)).toEqual(["agent-session-attach", "agent-session-prompt", "agent-session-share-revoke"]);
  expect(frames[1]).toMatchObject({ surface: 7, text: "marker" });
  expect(frames[2].share_id).toBe("room-7");
});

test("an exact held guest record on the right surface counts on the live push and the initial attach page", async () => {
  const held = { kind: "queued", msg: { promptId: "g-1", awaitingOwner: true, text: "guest words" } };
  const request = { operation: "wait_guest", surface: 1, text: "guest words" };
  for (const via of ["page", "before reply", "after reply"]) {
    const out = await machine(request, (_frame, push) => {
      const frame = { event: "agent-session-record", surface: 1, record: held };
      if (via === "before reply") push(frame);
      if (via === "after reply") setTimeout(() => push(frame), 10);
      return { events: via === "page" ? [held] : [] };
    });
    expect(out.result.ok).toBe(true);
  }
  const unrelated = [ { ...held, msg: { ...held.msg, promptId: "owner-1" } },
    { ...held, msg: { ...held.msg, awaitingOwner: false } }, { ...held, msg: { ...held.msg, text: "guest words 2" } } ];
  const out = await machine(request, () => ({ events: unrelated }), true);
  expect(out.code).toBe(1);
  expect(out.result.error).toBe("owner_socket_timed_out");
});

test("the warm carrier reads a bounded receipt from the owner process and propagates a refusal", async () => {
  const frames: Frame[] = [];
  const dial = { request: async (frame: Frame, timeoutMs?: number) => {
    expect(timeoutMs).toBe(8000);
    frames.push(frame);
    return { ok: true, data: frame.cmd === "shell-run" ? { run: "run" } : { output: '{"ok":true}\n', next: 12 } };
  } };
  const action = { operation: "prompt" as const, surface: 8, text: "marker" };
  const lower = performance.now();
  const times = await measured(dial, "/tmp/share-123-1", action);
  expect(times.sent).toBeGreaterThanOrEqual(lower);
  expect(times.observed).toBeGreaterThanOrEqual(times.sent);
  expect(frames.map(f => f.cmd)).toEqual(["shell-run", "shell-read"]);
  expect(frames[1].wait_ms).toBe(5000);
  expect(JSON.parse(Buffer.from(frames[0].command.split(" ")[2], "base64").toString("utf8"))).toEqual(action);
  const refused = { request: async () => ({ ok: true, data: { refused: "folder_missing" } }) };
  await expect(measured(refused, "/tmp/share-123-1", action)).rejects.toThrow("Start owner prompt: folder_missing");
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
