import { describe, expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FirstTextTiming, firstTextCommand, observeFirstText, probeRow, type Step } from "./cloud-journey";

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

  test.skipIf(!process.env.CMUX_JOURNEY_IMPORTER_FIXTURE)("producer failure fixture matches the importer's JSON content", () => {
    // Supply the importer's checked-in fixture; this check needs no network or credentials.
    const producer = JSON.parse(readFileSync(join(import.meta.dir, "cloud-journey-failure.fixture.json"), "utf8"));
    const importer = JSON.parse(readFileSync(process.env.CMUX_JOURNEY_IMPORTER_FIXTURE!, "utf8"));
    expect(producer).toEqual(importer);
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

  test("signal during deletion awaits the shared cleanup promise", async () => {
    const dir = mkdtempSync(join(tmpdir(), "journey-delete-cancel-"));
    try {
      const script = join(dir, "cancel.ts");
      writeFileSync(script, `import { finishJourney, sharedCleanup } from ${JSON.stringify(join(import.meta.dir, "cloud-journey.ts"))};
let calls = 0;
const cleanup = sharedCleanup(async () => {
  calls++;
  console.log("deleting");
  await new Promise<void>(resolve => process.stdin.once("data", () => resolve()));
  console.log("deleted " + calls);
});
const onSignal = () => { console.log("signal received"); void cleanup().then(() => process.exit(0)); };
process.on("SIGTERM", onSignal);
process.on("SIGINT", onSignal);
await finishJourney(cleanup, new Promise<void>(() => {}), onSignal);
`);
      const child = spawn(process.execPath, [script], { stdio: ["pipe", "pipe", "pipe"] });
      let output = "";
      let signalled = false;
      let released = false;
      const code = await new Promise<number | null>((resolve, reject) => {
        const timer = setTimeout(() => { child.kill("SIGKILL"); reject(new Error("delete cancel fixture timed out")); }, 5000);
        child.stdout.on("data", data => {
          output += data.toString();
          if (!signalled && output.includes("deleting")) { signalled = true; child.kill("SIGTERM"); }
          if (!released && output.includes("signal received")) { released = true; child.stdin.end("finish delete"); }
        });
        child.on("error", reject);
        child.on("close", code => { clearTimeout(timer); resolve(code); });
      });
      expect(code).toBe(0);
      expect(output).toContain("deleted 1");
    } finally { rmSync(dir, { recursive: true, force: true }); }
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
