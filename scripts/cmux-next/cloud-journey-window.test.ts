import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { JOURNEY_ONLY_STEPS, publicError, publicMachineFacts, spareFields, type Step } from "./cloud-journey";

type Fixture = { spare: "report" | "none"; exec: "ok" | "unavailable" };

/**
 * The whole journey (`main`) against a fake Cloud API, as cloud-journey-first-text.test.ts drives it: create answers,
 * the machine runs, every exec is answered by what its command asks (or refused 503 vm_unavailable), and the chat's
 * first text and reply come back at once. Returns journey.json's steps, probe.json and the fake's request log.
 */
function runJourney(fixture: Fixture): { steps: Step[]; probe: any; log: string[]; stdout: string } {
  const dir = mkdtempSync(join(tmpdir(), "journey-window-"));
  try {
    const script = join(dir, "journey.ts");
    const out = join(dir, "out");
    const probe = join(dir, "probe.json");
    writeFileSync(script, `import { main } from ${JSON.stringify(join(import.meta.dir, "cloud-journey.ts"))};
const fixture = ${JSON.stringify(fixture)};
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
  return answer("");
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
  if (route.endsWith("/fs/write")) return json({ ok: false, error: { code: "not_found" } }, 404);
  if (route.endsWith("/carrier")) return json({ ok: true, value: { relay: "relay+do://relay.fixture.invalid", slot: "slot1", ticket: "ticket", expires_at: Math.floor(Date.now() / 1000) + 600, grant: "grant", daemon_key: Buffer.alloc(32, 7).toString("base64url") } });
  if (route === "/v1/handoffs") return json({ error: "not found" }, 404);
  const op = body.op;
  if (op === "user.teams.list") return json({ ok: true, value: { teams: [{ id: "team_personal", kind: "personal" }] } });
  if (op === "user.ensure") return json({ ok: true, value: { id: "fixture-user" } });
  if (op === "install.register") return json({ ok: true, value: { id: "fixture-install", user: "fixture-user" } });
  if (op === "cloud.machine.list") return json({ ok: true, value: { machines: createdAt && !deleted ? [{ id: "vm_01JFIXTURE7Q", name: "fixture", status: "running" }] : [] } });
  if (op === "cloud.machine.create") {
    createdAt = Date.now();
    const report = fixture.spare === "report" ? { spare_fallback: "all_skipped", spare_skips: { restarting: 1, image: 1 } } : {};
    return json({ ok: true, value: { machine: { id: "vm_01JFIXTURE7Q", status: "creating" }, ...report } });
  }
  if (op === "cloud.machine.get") {
    log("get");
    return json({ ok: true, value: { id: "vm_01JFIXTURE7Q", status: deleted ? "deleted" : "running", host: "host-fixture.internal", ready: true, image: { daemon_version: "0.9.1" } } });
  }
  if (op === "cloud.machine.connect_info") return json({ ok: true, value: { host: "h", state: "running", epoch: 1 } });
  if (op === "cloud.machine.delete") { log("delete"); deleted = true; return json({ ok: true, value: {} }); }
  log("unexpected " + route + " " + op);
  return json({ ok: false, error: { code: "fixture.unexpected" } }, 404);
}) as typeof fetch;
process.exit(await main(["--api", "https://fixture.invalid", "--model", "real", "--skip", "lifecycle,keys,pause", "--out", ${JSON.stringify(out)}, "--probe-out", ${JSON.stringify(probe)}]));
`);
    const r = spawnSync(process.execPath, [script], {
      encoding: "utf8",
      timeout: 60_000,
      env: { PATH: process.env.PATH, CMUX_DOGFOOD_STACK_EMAIL: "fixture@example.invalid", CMUX_DOGFOOD_STACK_PASSWORD: "fixture-password" },
    });
    const steps = JSON.parse(readFileSync(join(out, "journey.json"), "utf8")).steps as Step[];
    const log = r.stdout.split("\n").filter((l) => l.startsWith("@@fake ")).map((l) => l.slice(7));
    return { steps, probe: JSON.parse(readFileSync(probe, "utf8")), log, stdout: r.stdout };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const journeyOnly = (name: string) => (JOURNEY_ONLY_STEPS as readonly string[]).includes(name);

describe("the first-text window holds only what a person's chat waits on", () => {
  test("no journey-only step is recorded between running and first text; each still runs, after the reply", () => {
    const { steps, probe } = runJourney({ spare: "report", exec: "ok" });
    // A step recorded while the machine runs and no first text has come yet is inside J.firstText's window.
    const inWindow = steps.filter((s) => s.fields?.create_marks_ms?.running !== undefined && s.fields.create_marks_ms.first_text === undefined);
    expect(inWindow.map((s) => s.step)).toContain("running (status)");
    expect(inWindow.filter((s) => journeyOnly(s.step)).map((s) => s.step)).toEqual([]);
    const reply = steps.findIndex((s) => s.step === "reply");
    expect(steps[reply]?.status).toBe("pass");
    for (const name of ["listed", "first exec", "machine facts", "GitHub on the machine (stub)"]) {
      const at = steps.findIndex((s) => s.step === name);
      expect(at).toBeGreaterThan(reply);
      expect(steps[at].status).not.toBe("fail");
    }
    expect(probe.outcome).toBe("ok");
    expect(probe.create_to_first_text_ms).toBeNumber();
  });
});

describe("probe.json says whether the row was a spare hit", () => {
  test("the claim answer's spare_fallback and spare_skips, and claimed_spare from the guest timeline", () => {
    const { probe } = runJourney({ spare: "report", exec: "ok" });
    expect(probe.spare_fallback).toBe("all_skipped");
    expect(probe.spare_skips).toEqual({ restarting: 1, image: 1 });
    expect(probe.claimed_spare).toBe(true);
    expect(probe).not.toHaveProperty("failure_facts");
  });

  test("null while the claim answer carries neither field", () => {
    const { probe } = runJourney({ spare: "none", exec: "ok" });
    expect(probe).toHaveProperty("spare_fallback", null);
    expect(probe).toHaveProperty("spare_skips", null);
    expect(probe.claimed_spare).toBe(true);
  });

  test("only counts and reason tokens get through", () => {
    expect(publicError('exec: HTTP 503 "vm_unavailable" on vm_01JABCDEF9 at https://x.invalid/v1 from 10.1.2.3')).toBe('exec: HTTP 503 "vm_unavailable" on <id> at <url> from <addr>');
    expect(spareFields({ spare_fallback: "no_spare", spare_skips: { restarting: 2, "vm_abc host": 1, image: -1, stale: 1.5 } })).toEqual({ spare_fallback: "no_spare", spare_skips: { restarting: 2 } });
    expect(spareFields({ spare_fallback: "vm_0123 was lost", spare_skips: ["restarting"] })).toEqual({ spare_fallback: null, spare_skips: null });
    expect(spareFields({ spare_fallback: null, spare_skips: {} })).toEqual({ spare_fallback: null, spare_skips: {} });
    expect(publicMachineFacts({ id: "vm_x", host: "h.internal", status: "running", ready: false, team: "team_1", image: { daemon_version: "0.9.1", id: "img_1" }, updater: { flip: "pending", target: "vm_y" } }))
      .toEqual({ status: "running", ready: false, daemon_version: "0.9.1", updater_flip: "pending" });
  });
});

describe("a failed step after create reads the machine's facts before anything is deleted", () => {
  test("a claimed machine answering 503 vm_unavailable: the first exec says so, the facts are read, then the delete", () => {
    const { steps, probe, log } = runJourney({ spare: "report", exec: "unavailable" });
    const failed = steps.filter((s) => s.status === "fail");
    // The agent start is now the first step to reach the machine: it names the unavailable machine.
    expect(failed[0].step).toBe("start agent (claude)");
    expect(failed[0].detail).toContain("did not take its first exec");
    expect(failed[0].detail).toContain("vm_unavailable");
    // The journey-only checks still ran, and `first exec` still fails on it.
    expect(steps.find((s) => s.step === "first exec")?.status).toBe("fail");
    const facts = steps.findIndex((s) => s.step === "failure facts");
    const del = steps.findIndex((s) => s.step === "delete (cleanup)");
    expect(facts).toBeGreaterThan(-1);
    expect(del).toBeGreaterThan(facts);
    expect(steps[del].status).toBe("pass");
    // In the fake's own order: the facts' get and timeline exec, then the delete.
    expect(log.indexOf("exec timeline")).toBeGreaterThan(-1);
    expect(log.indexOf("delete")).toBeGreaterThan(log.indexOf("exec timeline"));
    expect(log.lastIndexOf("get", log.indexOf("delete"))).toBeGreaterThan(-1);
    expect(probe.outcome).toBe("fail");
    expect(probe.failure_facts.machine).toEqual({ status: "running", ready: true, daemon_version: "0.9.1" });
    expect(probe.failure_facts.timeline).toBeNull();
    expect(probe.failure_facts.timeline_error).toContain("vm_unavailable");
    expect(probe.spare_fallback).toBe("all_skipped");
    expect(probe.claimed_spare).toBeNull();
    // probe.json is public: no machine id, host or token.
    const text = JSON.stringify(probe);
    for (const leak of ["vm_01JFIXTURE7Q", "host-fixture", "fake-access", "fake-install-token"]) expect(text).not.toContain(leak);
  });
});
