import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FirstTextTiming, firstTextCommand, observeFirstText, probeRow, resolveBackend, type Step } from "./cloud-journey";

const chunk = (kind = "agent_message_chunk", text = "hello") => ({
  kind,
  msg: { params: { update: { sessionUpdate: kind, content: { type: "text", text } } } },
});

describe("create to streamed first text", () => {
  test("one monotonic clock, snapshots, and no create time for a reused machine", () => {
    let now = 100;
    const timing = new FirstTextTiming(() => now);
    timing.mark("running");
    expect(timing.fields()).toEqual({});
    timing.mark("create");
    now = 120;
    timing.mark("running");
    const before = timing.fields();
    now = 145;
    timing.mark("first_text");
    now = 190;
    timing.mark("first_text");
    expect(before).toEqual({ create_marks_ms: { create: 0, running: 20 } });
    expect(timing.fields()).toEqual({ create_marks_ms: { create: 0, running: 20, first_text: 45 }, create_to_first_text_ms: 45 });
  });

  test("the observer records text before the turn completes and never rejects unhandled", async () => {
    let now = 0;
    const timing = new FirstTextTiming(() => now);
    timing.mark("create");
    const steps: Step[] = [];
    now = 900;
    await observeFirstText(async () => ({ code: 0, stdout: "@@first-text\n", stderr: "" }), "new-session", 5000, timing, (s) => steps.push(s));
    expect(steps[0].fields?.create_to_first_text_ms).toBe(900);
    expect(steps[0].ms).toBe(0); // overlapping observer is not another sequential duration
    expect(steps[0].status).toBe("pass");
    const missing = new FirstTextTiming(() => now);
    missing.mark("create");
    await observeFirstText(async () => { throw new Error("transport closed"); }, "s", 5000, missing, (s) => steps.push(s));
    expect(steps[1]).toMatchObject({ status: "pass", detail: "measurement unavailable: transport closed" });
    expect(steps[1].fields).not.toHaveProperty("create_to_first_text_ms");
  });

  function runTail(program: string, budget = 2000) {
    const dir = mkdtempSync(join(tmpdir(), "journey-first-text-"));
    try {
      const bin = join(dir, "tail-fixture");
      writeFileSync(bin, `#!/usr/bin/env python3\nimport json, os, signal, sys, time\n${program}\n`, { mode: 0o755 });
      return spawnSync("bash", ["-c", `c='${bin}'; ${firstTextCommand("fresh-session", budget)}`], { encoding: "utf8", timeout: 5000 });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  test("streams split JSON and UTF-8, ignores thoughts/tools/empty text, returns before end", () => {
    const ignored = [chunk("agent_thought_chunk"), chunk("tool_call"), chunk("agent_message_chunk", "")];
    const lines = [{ kind: "turn_started" }, ...ignored].map((v) => JSON.stringify(v)).join("\n") + "\n";
    const text = JSON.stringify(chunk("agent_message_chunk", "héllo")) + "\n";
    const result = runTail(`assert sys.argv[1:] == ['acp', 'tail', 'fresh-session', '--since', '0', '--follow']
os.write(1, ${JSON.stringify(lines)}.encode())
data = ${JSON.stringify(text)}.encode()
for b in data: os.write(1, bytes([b]))
time.sleep(10) # a turn whose end must never be awaited`);
    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe("@@first-text");
    expect(result.stdout).not.toContain("héllo");
  });

  test("accepts the live session/update shape", () => {
    const live = { method: "session/update", params: chunk().msg.params };
    expect(runTail(`print('{"kind":"turn_started"}', flush=True)\nprint(${JSON.stringify(JSON.stringify(live))}, flush=True)`).stdout.trim()).toBe("@@first-text");
  });

  test.each([
    ["EOF without text", "pass", 2000],
    ["text before a turn starts", `print(${JSON.stringify(JSON.stringify(chunk()))}, flush=True)`, 2000],
    ["turn ends without text", `print('{"kind":"turn_result"}', flush=True)`, 2000],
    ["thoughts alone", `print(${JSON.stringify(JSON.stringify(chunk("agent_thought_chunk")))}, flush=True)`, 2000],
    ["hung stream", "time.sleep(10)", 100],
    ["oversized line", "os.write(1, b'x' * 1100000)", 2000],
  ])("%s fails without manufacturing a number", (_name, program, budget) => {
    const result = runTail(program as string, budget as number);
    expect(result.status).not.toBe(0);
    expect(result.stdout).not.toContain("@@first-text");
  });


  test("early failure writes the actual producer envelope consumed by the importer", () => {
    const dir = mkdtempSync(join(tmpdir(), "journey-fail-contract-"));
    try {
      const out = join(dir, "probe.json");
      const result = spawnSync(process.execPath, [join(import.meta.dir, "cloud-journey.ts"),
        "--backend", "prod", "--model", "real", "--sign-in", "invalid", "--probe-out", out,
        "--probe", "cloud-chat-replies-production-real-model"], { encoding: "utf8", timeout: 5000,
        env: { PATH: process.env.PATH, GITHUB_SERVER_URL: "https://github.com", GITHUB_REPOSITORY: "manaflow-ai/cmux", GITHUB_RUN_ID: "10", GITHUB_RUN_ATTEMPT: "1" } });
      expect(result.status).not.toBe(0);
      const actual = JSON.parse(readFileSync(out, "utf8"));
      expect(Number.isFinite(Date.parse(actual.at))).toBe(true);
      const fixture = JSON.parse(readFileSync(join(import.meta.dir, "cloud-journey-failure.fixture.json"), "utf8"));
      // Only the wall-clock timestamp varies; the remaining JSON content matches (formatting may differ).
      expect({ ...actual, at: fixture.at }).toEqual(fixture);
      console.log(`producer failure contract: ${JSON.stringify({ ...actual, at: fixture.at })}`);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  test("producer failure fixture matches the shared importer contract", () => {
    // Same canonical-JSON SHA256 as the importer's default fixture test. No opt-in or network.
    const expected = "bc6e49fa64ad47614bc643998a52eccdcd07d208ba737f19225d1d83b28a5a2d";
    const fixture = JSON.parse(readFileSync(join(import.meta.dir, "cloud-journey-failure.fixture.json"), "utf8"));
    const canonical = JSON.stringify(fixture, Object.keys(fixture).sort());
    expect(createHash("sha256").update(canonical).digest("hex")).toBe(expected);
  });

  test.each([
    ["production", undefined, "prod"], ["prod", undefined, "prod"],
    ["development", undefined, "dev"], ["dev", undefined, "dev"],
    ["staging", undefined, "staging"], ["local", undefined, "local"],
    ["preview-123", undefined, "preview-123"],
    ["", "https://fixture.invalid", "custom"],
    ["production", "https://fixture.invalid", "production"],
    ["development", "https://fixture.invalid", "development"],
  ])("failure envelope backend %s agrees with the resolved backend (%s)", (name, api, expected) => {
    const dir = mkdtempSync(join(tmpdir(), "journey-backend-envelope-"));
    try {
      const probe = join(dir, "probe.json");
      const result = spawnSync(process.execPath, [join(import.meta.dir, "cloud-journey.ts"),
        "--backend", name!, ...(api ? ["--api", api] : []), "--sign-in", "invalid", "--probe-out", probe],
        { encoding: "utf8", timeout: 5000, env: { PATH: process.env.PATH } });
      expect(result.status).not.toBe(0);
      expect(resolveBackend(name!, api).name).toBe(expected);
      expect(JSON.parse(readFileSync(probe, "utf8")).backend).toBe(expected);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  test.each([
    ["stub", ["--model", "stub"], "stub"],
    ["gateway stub by default", ["--gateway", "machine"], "stub"],
    ["gateway stub explicitly", ["--gateway", "machine", "--gateway-upstream", "stub"], "stub"],
    ["gateway real", ["--gateway", "machine", "--gateway-upstream", "real"], "real"],
    ["backend validation", ["--backend", "unknown"], "real"],
    ["output mkdir", ["--out", "BLOCKED"], "real"],
  ])("failure envelope survives %s", (_name, args, model) => {
    const dir = mkdtempSync(join(tmpdir(), "journey-envelope-"));
    try {
      const probe = join(dir, "probe.json");
      const blocked = join(dir, "not-a-directory");
      writeFileSync(blocked, "file");
      const flags = (args as string[]).map(a => a === "BLOCKED" ? blocked : a);
      const result = spawnSync(process.execPath, [join(import.meta.dir, "cloud-journey.ts"),
        ...flags, ...(flags.includes("--backend") ? [] : ["--backend", "production"]),
        "--sign-in", "invalid", "--probe-out", probe], { encoding: "utf8", timeout: 5000,
        env: { PATH: process.env.PATH } });
      expect(result.status).not.toBe(0);
      const actual = JSON.parse(readFileSync(probe, "utf8"));
      expect(actual.outcome).toBe("fail");
      expect(actual.model).toBe(model);
      expect(actual.backend).toBe(flags.includes("--backend") ? "unknown" : "prod");
      expect(actual).not.toHaveProperty("create_to_first_text_ms");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  test("main handles a second signal while its actual machine deletion is pending", async () => {
    const dir = mkdtempSync(join(tmpdir(), "journey-main-delete-cancel-"));
    let child: ReturnType<typeof spawn> | undefined;
    try {
      const script = join(dir, "cancel.ts");
      const out = join(dir, "out");
      const probe = join(dir, "probe.json");
      writeFileSync(script, `import { main } from ${JSON.stringify(join(import.meta.dir, "cloud-journey.ts"))};
const json = (value: unknown) => new Response(JSON.stringify(value), { status: 200 });
let deletes = 0;
globalThis.fetch = (async (input: string, init: RequestInit = {}) => {
  const url = new URL(String(input));
  const body = init.body ? JSON.parse(String(init.body)) : {};
  if (url.pathname === "/v1/health") return json({ commit: "fixture" });
  if (url.pathname === "/api/v1/auth/password/sign-in") return json({ access_token: "fake-access", refresh_token: "fake-refresh" });
  if (url.pathname === "/v1/auth/challenge") return json({ nonce: "fake-nonce", message_prefix: "fixture:" });
  if (url.pathname === "/v1/auth/token") return json({ access_token: "fake-install-token" });
  if (body.op === "user.ensure") return json({ ok: true, value: { id: "fixture-user" } });
  if (body.op === "install.register") return json({ ok: true, value: { id: "fixture-install", user: "fixture-user" } });
  if (body.op === "cloud.machine.list") return json({ ok: true, value: { machines: [] } });
  if (body.op === "cloud.machine.create") return json({ ok: true, value: { machine: { id: "fixture-machine", status: "creating" } } });
  if (body.op === "cloud.machine.get") {
    console.log("ready for first signal");
    return await new Promise<Response>(() => {});
  }
  if (body.op === "cloud.machine.delete") {
    if (body.params.machine !== "fixture-machine") throw new Error("wrong machine");
    deletes++;
    console.log("delete pending");
    await new Promise<void>(resolve => process.stdin.once("data", () => resolve()));
    console.log("delete completed " + deletes);
    return json({ ok: true, value: {} });
  }
  throw new Error("unexpected fixture request " + url.pathname + " " + body.op);
}) as typeof fetch;
setInterval(() => {}, 1000); // Keep the simulated in-flight fetch alive until main exits.
const done = main(["--api", "https://fixture.invalid", "--model", "stub", "--out", ${JSON.stringify(out)}, "--probe-out", ${JSON.stringify(probe)}]);
// Observe delivery only. main installs and executes the real cleanup/exit handlers.
process.on("SIGTERM", () => console.log("observed SIGTERM"));
process.on("SIGINT", () => console.log("observed SIGINT"));
process.exit(await done);
`);
      child = spawn(process.execPath, [script], { stdio: ["pipe", "pipe", "pipe"],
        env: { PATH: process.env.PATH, CMUX_DOGFOOD_STACK_EMAIL: "fixture@example.invalid", CMUX_DOGFOOD_STACK_PASSWORD: "fixture-password" } });
      let output = "";
      let stderr = "";
      let first = false;
      let second = false;
      let released = false;
      const code = await new Promise<number | null>((resolve, reject) => {
        const timer = setTimeout(() => { child!.kill("SIGKILL"); reject(new Error("main cancel fixture timed out: " + output + stderr)); }, 5000);
        child!.stdout!.on("data", data => {
          output += data.toString();
          if (!first && output.includes("ready for first signal")) { first = true; child!.kill("SIGTERM"); }
          if (!second && output.includes("delete pending")) { second = true; child!.kill("SIGINT"); }
          if (!released && output.includes("observed SIGINT")) { released = true; child!.stdin!.end("finish delete"); }
        });
        child!.stderr!.on("data", data => { stderr += data.toString(); });
        child!.on("error", error => { clearTimeout(timer); reject(error); });
        child!.on("close", code => { clearTimeout(timer); resolve(code); });
      });
      expect(code).toBe(143);
      expect(output).toContain("observed SIGTERM");
      expect(output).toContain("observed SIGINT");
      expect(output).toContain("delete completed 1");
      const result = JSON.parse(readFileSync(join(out, "journey.json"), "utf8"));
      expect(result.steps.filter((s: Step) => s.step === "delete (cleanup)" && s.status === "pass")).toHaveLength(1);
      expect(JSON.parse(readFileSync(probe, "utf8")).outcome).toBe("fail");
    } finally {
      if (child && child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("cancellation during observer finalization keeps cleanup installed", async () => {
    const dir = mkdtempSync(join(tmpdir(), "journey-cancel-"));
    try {
      const script = join(dir, "cancel.ts");
      writeFileSync(script, `import { finishJourney } from ${JSON.stringify(join(import.meta.dir, "cloud-journey.ts"))};
let cleaned = false;
const cleanup = async () => { cleaned = true; };
const onSignal = () => { if (!cleaned) process.exit(3); console.log("cancel-clean"); process.exit(0); };
process.on("SIGTERM", onSignal);
process.on("SIGINT", onSignal);
setInterval(() => {}, 1000); // an outstanding exec keeps the real journey alive
const observer = new Promise<void>(() => {});
const done = finishJourney(cleanup, observer, onSignal);
setTimeout(() => console.log("waiting"), 0);
await done;
`);
      const child = spawn(process.execPath, [script], { stdio: ["ignore", "pipe", "pipe"] });
      const output: string[] = [];
      let signalled = false;
      const code = await new Promise<number | null>((resolve, reject) => {
        const timer = setTimeout(() => { child.kill("SIGKILL"); reject(new Error("cancel fixture timed out")); }, 5000);
        child.stdout.on("data", (data) => { output.push(data.toString()); if (!signalled && output.join("").includes("waiting")) { signalled = true; child.kill("SIGTERM"); } });
        child.on("error", reject);
        child.on("close", (code) => { clearTimeout(timer); resolve(code); });
      });
      expect(code).toBe(0);
      expect(output.join("")).toContain("cancel-clean");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  test.each(["user_message_chunk", "user_message_chunk.replay", "agent_message_chunk.replay", "subagent_message_chunk", "subagent metadata"])("ignores %s even with assistant-shaped payload", (kind) => {
    const event: any = { ...chunk(), kind };
    if (kind === "subagent metadata") {
      event.kind = "agent_message_chunk";
      event.msg.params._meta = { acpmux: { subagent: "child" } };
    }
    const result = runTail(`print('{"kind":"turn_started"}', flush=True)\nprint(${JSON.stringify(JSON.stringify(event))}, flush=True)\nprint('{"kind":"turn_result"}', flush=True)`);
    expect(result.status).not.toBe(0);
    expect(result.stdout).not.toContain("@@first-text");
  });

  test("skips an oversized line and resumes on the next assistant chunk", () => {
    const result = runTail(`print('{"kind":"turn_started"}', flush=True)\nos.write(1, b'x' * 1100000 + b'\\n')\nprint(${JSON.stringify(JSON.stringify(chunk()))}, flush=True)`);
    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe("@@first-text");
  });

  test("preserves completion ms; only a real model exports first-text fields", () => {
    const steps: Step[] = [
      { step: "send chat", status: "pass", ms: 800, detail: "" },
      { step: "first text", status: "pass", ms: 0, detail: "", fields: { create_marks_ms: { create: 0, first_text: 10000 }, create_to_first_text_ms: 10000 } },
      { step: "reply", status: "pass", ms: 4200, detail: "" },
    ];
    const real = probeRow("old-probe", steps, undefined, new Date(), { backend: "prod", model: "real" });
    expect(real).toMatchObject({ ms: 5000, create_to_first_text_ms: 10000, model: "real", backend: "prod" });
    const stub = probeRow("old-probe", steps, undefined, new Date(), { backend: "prod", model: "stub" });
    expect(stub.ms).toBe(5000);
    expect(stub).not.toHaveProperty("create_to_first_text_ms");
    expect(probeRow("p", steps.slice(0, 1))).not.toHaveProperty("create_to_first_text_ms");
  });
});
