/**
 * `cmux host run` smoke on one clone of a baked image (bead cx-3bi.29). Checks, in order:
 * - roles: `cmux host roles --json` answers with a roles array (process roles; none are configured
 *   in this image), `cmux host status` answers, and the in-process cloud role logged its start;
 * - link-terminal: a terminal over the session host's 1337 listener (enroll, open a workspace,
 *   spawn a PTY process, read it back), the listener the Freestyle edge reaches;
 * - restart-keeps-terminal: a daemon PTY tab survives `systemctl restart cmux-host.service`
 *   (same shell, same terminal-host scope), because the host runs in its own systemd scope; the
 *   re-adopted tab keeps its workspace and screen under a new surface id;
 * - activity: the daemon's subscribe-activity stream reports a person's input in the terminal;
 * - resume: a provider pause and start makes the supervisor notify `resumed`, and the terminal
 *   is still there.
 * A real bind and the reports it sends need the dev API to boot this snapshot; dev-e2e.ts does
 * that once the dev channel names it.
 *
 * Usage (from web/): bun scripts/cmux-vm-image/host-run-smoke.ts --snapshot <id> [--out-dir <dir>]
 * The clone is recorded in the ledger at create and deleted by its exact id at the end.
 */
import path from "node:path";
import { cmuxTuiWebsocketSmokeCommand } from "../devbox-image-common";
import { argValue, createVm, deleteVm, firstExec, freestyleClient, Ledger, run, sleep, type Vm } from "./guest";
import { HOST_CLI, HOST_UNIT } from "./host-agent";

/** One daemon-socket client: `python3 - <op> [args]`; prints one JSON line. */
const DAEMON_PY = String.raw`
import json, socket, sys, time
sock_path = open("/etc/cmux/daemon-socket").read().strip()
s = socket.socket(socket.AF_UNIX); s.settimeout(15); s.connect(sock_path)
f = s.makefile("rwb"); n = [0]
def rpc(obj):
    n[0] += 1; obj["id"] = n[0]
    f.write((json.dumps(obj) + "\n").encode()); f.flush()
    for line in f:
        msg = json.loads(line)
        if msg.get("id") == obj["id"]: return msg
op = sys.argv[1]
if op == "new":
    r = rpc({"cmd": "new-workspace", "name": "host-run-smoke", "cols": 100, "rows": 30})
    print(json.dumps({"surface": (r.get("data") or {}).get("surface"), "raw": r}))
elif op == "find":
    tree = rpc({"cmd": "list-workspaces"})["data"]
    found = [t["surface"] for w in tree["workspaces"] if w["name"] == "host-run-smoke" for sc in w["screens"] for p in sc["panes"] for t in p["tabs"] if t["kind"] == "pty"]
    print(json.dumps({"surface": found[0] if found else None}))
elif op == "send":
    rpc({"cmd": "set-client-info", "name": "smoke-person", "kind": "tui"})
    rpc({"cmd": "attach-surface", "surface": int(sys.argv[2])})
    r = rpc({"cmd": "send", "surface": int(sys.argv[2]), "text": sys.argv[3] + "\r"})
    print(json.dumps({"ok": bool(r and r.get("ok")), "sent_at_ms": int(time.time() * 1000), "raw": r}))
elif op == "screen":
    r = rpc({"cmd": "read-screen", "surface": int(sys.argv[2])})
    print(json.dumps({"ok": bool(r.get("ok")), "text": (r.get("data") or {}).get("text", ""), "error": r.get("error")}))
`;

type Check = { name: string; ok: boolean; detail: string };

async function daemon(vm: Vm, args: string): Promise<Record<string, unknown>> {
  await vm.fs.writeFile("/root/host-run-smoke.py", DAEMON_PY, { mode: 0o644 });
  const r = await run(vm, `python3 /root/host-run-smoke.py ${args}`, 60_000);
  if (r.code !== 0) throw new Error(`daemon ${args}: ${r.stderr.slice(-300)}`);
  return JSON.parse(r.stdout.trim().split("\n").at(-1) ?? "{}") as Record<string, unknown>;
}

const SCOPES = "systemctl list-units --type=scope --state=running --no-legend --plain | awk '{print $1}' | grep -i cmux | sort";
const READY = `for i in $(seq 1 120); do ss -Hltn "sport = :1337" | grep -q . && test -S "$(cat /etc/cmux/daemon-socket)" && break; sleep 0.5; done; systemctl is-active ${HOST_UNIT}`;

async function screenHas(vm: Vm, surface: string, marks: string[], budgetMs = 20_000): Promise<string> {
  const t0 = Date.now();
  let text = "";
  while (Date.now() - t0 < budgetMs) {
    const r = await daemon(vm, `screen ${surface}`);
    text = String(r.text ?? "");
    if (marks.every((m) => text.includes(m))) return text;
    await sleep(500);
  }
  throw new Error(`screen lacks ${marks.join(",")}: ${text.slice(-300)}`);
}

async function main(): Promise<number> {
  const snapshotId = argValue("--snapshot");
  if (!snapshotId) throw new Error("usage: host-run-smoke.ts --snapshot <id> [--out-dir <dir>]");
  const stamp = new Date().toISOString().replace(/[-:]/g, "").slice(0, 15).toLowerCase();
  const outDir = path.resolve(argValue("--out-dir") ?? `cmux-vm-image-out/host-run-${stamp}`);
  const ledger = new Ledger(path.join(outDir, "resources.tsv"));
  const fs = freestyleClient();
  const checks: Check[] = [];
  const step = async (name: string, fn: () => Promise<string>) => {
    try {
      const detail = await fn();
      checks.push({ name, ok: true, detail });
      console.log(`PASS ${name}: ${detail.replace(/\s+/g, " ").slice(0, 400)}`);
    } catch (error) {
      checks.push({ name, ok: false, detail: String(error) });
      console.log(`FAIL ${name}: ${String(error).replace(/\s+/g, " ").slice(0, 400)}`);
    }
  };
  const name = `cmuxnp-dev-vmimg-hostrun-smoke-${stamp}`;
  const { vm, vmId, t0 } = await createVm(fs, ledger, { name, snapshotId });
  console.log(`VM ${vmId}`);
  try {
    await firstExec(vm, t0);
    await run(vm, READY);
    await step("roles", async () => {
      const r = await run(vm, `${HOST_CLI} roles --json`);
      if (r.code !== 0) throw new Error(r.stderr.slice(-300));
      const roles = JSON.parse(r.stdout.trim()) as { roles?: unknown };
      if (!Array.isArray(roles.roles)) throw new Error(`no roles array: ${r.stdout.slice(0, 300)}`);
      const s = await run(vm, `${HOST_CLI} status`);
      if (s.code !== 0) throw new Error(`status: ${s.stderr.slice(-300)}`);
      const cloud = (await run(vm, `journalctl -m -u ${HOST_UNIT} --no-pager -o cat | grep 'cmux-host: cloud:' | tail -2`)).stdout.trim();
      if (!cloud) throw new Error("the cloud role logged nothing");
      return `roles ${r.stdout.trim()} | status ${s.stdout.trim().split("\n").slice(0, 4).join("; ")} | ${cloud.split("\n").join(" | ")}`;
    });
    await step("link-terminal", async () => {
      const r = await run(vm, cmuxTuiWebsocketSmokeCommand(), 180_000);
      if (r.code !== 0 || !r.stdout.includes("websocket-smoke-ok")) throw new Error(`${r.stdout.slice(-300)} ${r.stderr.slice(-300)}`);
      return r.stdout.trim().split("\n").at(-1) ?? "";
    });
    const created = await daemon(vm, "new");
    let surface = String(created.surface);
    /** The re-adopted tab has a new surface id after a daemon restart: look it up by workspace. */
    const refind = async () => {
      const f = await daemon(vm, "find");
      if (f.surface === null || f.surface === undefined) throw new Error("the host-run-smoke workspace is gone");
      surface = String(f.surface);
    };
    const sentA = await daemon(vm, `send ${surface} 'echo HOSTRUN_A_$$'`);
    console.log(`daemon new ${JSON.stringify(created.raw).slice(0, 300)} send ${JSON.stringify(sentA.raw).slice(0, 300)}`);
    const before = await screenHas(vm, surface, ["HOSTRUN_A_"]);
    const shellA = /HOSTRUN_A_(\d+)/.exec(before.replace(/echo HOSTRUN_A_\$\$/g, ""))?.[1] ?? "";
    await step("restart-keeps-terminal", async () => {
      const scopes0 = (await run(vm, SCOPES)).stdout.trim();
      const r = await run(vm, `systemctl restart ${HOST_UNIT} && ${READY}`, 120_000);
      if (!/active/.test(r.stdout)) throw new Error(`unit not active after restart: ${r.stdout} ${r.stderr.slice(-200)}`);
      const scopes1 = (await run(vm, SCOPES)).stdout.trim();
      const old = surface;
      await refind();
      await daemon(vm, `send ${surface} 'echo HOSTRUN_B_$$'`);
      const after = await screenHas(vm, surface, ["HOSTRUN_A_", "HOSTRUN_B_"]);
      const shellB = /HOSTRUN_B_(\d+)/.exec(after.replace(/echo HOSTRUN_B_\$\$/g, ""))?.[1] ?? "";
      if (!shellA || shellA !== shellB) throw new Error(`shell changed: ${shellA} -> ${shellB}`);
      if (!scopes0 || scopes0 !== scopes1) throw new Error(`scopes changed: [${scopes0}] -> [${scopes1}]`);
      return `same shell pid ${shellA}; surface ${old} -> ${surface}; scopes ${scopes1.split("\n").join(",")}`;
    });
    await step("activity", async () => {
      const sent = await daemon(vm, `send ${surface} true`);
      const t = Number(sent.sent_at_ms);
      for (let i = 0; i < 20; i += 1) {
        const p = await run(vm, `${HOST_CLI} cloud probe-activity`, 30_000);
        const line = p.stdout.trim().split("\n").at(-1) ?? "{}";
        const a = (JSON.parse(line) as { activity?: { last_user_input_at?: number; active_sessions?: number } }).activity ?? {};
        if ((a.last_user_input_at ?? 0) >= t - 2_000) return `${line} (input sent at ${t})`;
        await sleep(500);
      }
      throw new Error("the activity stream never reported the input");
    });
    await step("resume", async () => {
      const since = Math.floor(Date.now() / 1000);
      await vm.pause();
      await sleep(5_000);
      await vm.start();
      await firstExec(vm, Date.now(), 120_000);
      let log = "";
      for (let i = 0; i < 40; i += 1) {
        log = (await run(vm, `journalctl -m -u ${HOST_UNIT} --since=@${since} --no-pager -o cat | grep -E 'resum' | tail -3`)).stdout.trim();
        if (/event=resumed/.test(log)) break;
        await sleep(1_000);
      }
      if (!/event=resumed/.test(log)) throw new Error(`no resumed notice: ${log.slice(-300)}`);
      const r = await run(vm, `systemctl is-active ${HOST_UNIT}`);
      await refind();
      await screenHas(vm, surface, ["HOSTRUN_B_"]);
      return `${log.split("\n").join(" | ")}; unit ${r.stdout.trim()}; terminal kept`;
    });
  } finally {
    await deleteVm(vm, vmId, name, ledger);
    console.log(`LEDGER ${ledger.file}`);
  }
  const failed = checks.filter((c) => !c.ok);
  console.log(failed.length === 0 ? "HOST_RUN_SMOKE PASSED" : `HOST_RUN_SMOKE FAILED: ${failed.map((c) => c.name).join(", ")}`);
  return failed.length === 0 ? 0 : 1;
}

process.exit(await main());
