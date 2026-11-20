// The whole Cloud journey (`main`) against a fake Cloud API, for the journey's own tests (cloud-journey-window.test.ts,
// cloud-journey-preclaim-login.test.ts), as cloud-journey-first-text.test.ts drives it: create answers, the machine
// runs, every exec is answered by what its command asks (or refused 503 vm_unavailable), and the chat's first text and
// reply come back at once. With `preclaim`, a fake cmux-tui answers warm-spare and a fake cloud wire sends the spare's
// cloud.spare.ready. No network, no secret.
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Step } from "./cloud-journey";

export type JourneyFixture = {
  spare?: "report" | "none";
  exec?: "ok" | "unavailable";
  /** --preclaim-login with a fake cmux-tui; `receipt` is what its loginReceipt answer says. */
  preclaim?: { receipt: boolean };
  /** CLAUDE_CODE_OAUTH_TOKEN; without one the login step is skipped. */
  login?: string;
};

export const FIXTURE_MACHINE = "vm_01JFIXTURE7Q";
export const FIXTURE_LOGIN = `sk-ant-oat01-${"a".repeat(40)}`;

export function runJourney(fixture: JourneyFixture): { steps: Step[]; probe: any; log: string[]; stdout: string } {
  const dir = mkdtempSync(join(tmpdir(), "journey-fake-"));
  try {
    const script = join(dir, "journey.ts");
    const out = join(dir, "out");
    const probe = join(dir, "probe.json");
    const args = ["--api", "https://fixture.invalid", "--model", "real", "--skip", "lifecycle,keys,pause", "--out", out, "--probe-out", probe];
    if (fixture.preclaim) {
      // warm-spare: a spare and a copy generation; ready and installed: an empty answer; loginReceipt: the fixture's.
      const cmux = join(dir, "cmux-tui");
      writeFileSync(cmux, [
        "#!/usr/bin/env bash",
        "cat >/dev/null",
        'req=""; while [ $# -gt 0 ]; do [ "$1" = --request ] && req="$2"; shift; done',
        `case "$req" in`,
        `  *'"loginReceipt"'*) echo '{"value":{"installed":${fixture.preclaim.receipt}}}' ;;`,
        `  *'"installed"'*|*'"ready"'*) echo '{"value":{}}' ;;`,
        `  *) echo '{"value":{"machine":"${FIXTURE_MACHINE}","copy":{"generation":1}}}' ;;`,
        "esac",
        "",
      ].join("\n"), { mode: 0o755 });
      args.push("--preclaim-login", cmux);
    }
    writeFileSync(script, `import { main } from ${JSON.stringify(join(import.meta.dir, "cloud-journey.ts"))};
const fixture = ${JSON.stringify({ spare: "report", exec: "ok", ...fixture })};
const MACHINE = ${JSON.stringify(FIXTURE_MACHINE)};
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });
const log = (line: string) => console.log("@@fake " + line);
let createdAt = 0;
let deleted = false;
const exec = (command: string) => {
  if (fixture.exec === "unavailable") return json({ ok: false, error: { code: "vm_unavailable" } }, 503);
  const answer = (stdout: string, exitCode = 0) => json({ ok: true, value: { exitCode, stdout, stderr: "" } });
  // The guest's boot 10 minutes ago and its bind 5 s before create was sent: a claimed spare.
  if (command.includes("guest_now")) return answer("guest_now " + Date.now() + " 600000\\nwall bound.json " + (createdAt - 5000) + "\\n");
  if (command.includes("CMUX_FIRST_TEXT")) return answer("@@first-text\\n");
  if (command.includes("acp ensure") || command.includes("acp send")) return answer("@@exit 0\\n");
  if (command.includes("acp wait")) return answer("@@wait 0\\nHello from the fixture.\\n@@lastexit 0\\n");
  if (command.includes("echo journey-ok")) return answer("journey-ok\\nx86_64\\n");
  if (command.includes("cmux_agent_has_own_login")) { log("own-login check"); return answer("own-login\\n"); }
  return answer("");
};
// The cloud wire: the spare's cloud.spare.ready right after the subscribe.
(globalThis as any).WebSocket = class {
  private listeners: Record<string, Array<(e: any) => void>> = {};
  constructor() { setTimeout(() => this.emit("open", {}), 0); }
  addEventListener(type: string, fn: (e: any) => void) { (this.listeners[type] ??= []).push(fn); }
  emit(type: string, e: any) { for (const fn of this.listeners[type] ?? []) fn(e); }
  send() { setTimeout(() => this.emit("message", { data: JSON.stringify({ event: "cloud.spare.ready", stream: "cloud", data: { machine: MACHINE } }) }), 0); }
  close() {}
};
globalThis.fetch = (async (input: string, init: RequestInit = {}) => {
  const url = new URL(String(input));
  const body = init.body ? JSON.parse(String(init.body)) : {};
  const route = url.pathname;
  if (route === "/v1/health") return json({ commit: "fixture" });
  if (route === "/api/v1/auth/password/sign-in") return json({ access_token: "fake-access", refresh_token: "fake-refresh" });
  if (route === "/v1/auth/challenge") return json({ nonce: "fake-nonce", message_prefix: "fixture:" });
  if (route === "/v1/auth/token") return json({ access_token: "fake-install-token" });
  if (route.endsWith("/client-session")) return json({ ok: false, error: { code: "cloud.provider.unsupported" } }, 501);
  if (route.endsWith("/exec")) { log("exec " + (String(body.command).includes("guest_now") ? "timeline" : "command")); return exec(String(body.command)); }
  if (route.endsWith("/fs/write")) {
    if (String(body.path).includes("/credential-transfer/")) { log("fs/write credential"); return json({ ok: true, value: {} }); }
    return json({ ok: false, error: { code: "not_found" } }, 404);
  }
  if (route.endsWith("/carrier")) return json({ ok: true, value: { relay: "relay+do://relay.fixture.invalid", slot: "slot1", ticket: "ticket", expires_at: Math.floor(Date.now() / 1000) + 600, grant: "grant", daemon_key: Buffer.alloc(32, 7).toString("base64url") } });
  if (route === "/v1/handoffs") return json({ error: "not found" }, 404);
  const op = body.op;
  if (op === "user.teams.list") return json({ ok: true, value: { teams: [{ id: "team_personal", kind: "personal" }] } });
  if (op === "user.ensure") return json({ ok: true, value: { id: "fixture-user" } });
  if (op === "install.register") return json({ ok: true, value: { id: "fixture-install", user: "fixture-user" } });
  if (op === "cloud.machine.list") return json({ ok: true, value: { machines: createdAt && !deleted ? [{ id: MACHINE, name: "fixture", status: "running" }] : [] } });
  if (op === "cloud.machine.create") {
    log("create");
    createdAt = Date.now();
    const report = fixture.spare === "report" ? { spare_fallback: "all_skipped", spare_skips: { restarting: 1, image: 1 } } : {};
    return json({ ok: true, value: { machine: { id: MACHINE, status: "creating" }, ...report } });
  }
  if (op === "cloud.machine.get") {
    log("get");
    return json({ ok: true, value: { id: MACHINE, status: deleted ? "deleted" : "running", host: "host-fixture.internal", ready: true, image: { daemon_version: "0.9.1" } } });
  }
  if (op === "cloud.machine.connect_info") return json({ ok: true, value: { host: "h", state: "running", epoch: 1 } });
  if (op === "cloud.machine.delete") { log("delete"); deleted = true; return json({ ok: true, value: {} }); }
  log("unexpected " + route + " " + op);
  return json({ ok: false, error: { code: "fixture.unexpected" } }, 404);
}) as typeof fetch;
process.exit(await main(${JSON.stringify(args)}));
`);
    const r = spawnSync(process.execPath, [script], {
      encoding: "utf8",
      timeout: 60_000,
      env: {
        PATH: process.env.PATH,
        CMUX_DOGFOOD_STACK_EMAIL: "fixture@example.invalid",
        CMUX_DOGFOOD_STACK_PASSWORD: "fixture-password",
        ...(fixture.login ? { CLAUDE_CODE_OAUTH_TOKEN: fixture.login } : {}),
      },
    });
    const steps = JSON.parse(readFileSync(join(out, "journey.json"), "utf8")).steps as Step[];
    const log = r.stdout.split("\n").filter((l) => l.startsWith("@@fake ")).map((l) => l.slice(7));
    return { steps, probe: JSON.parse(readFileSync(probe, "utf8")), log, stdout: r.stdout };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
