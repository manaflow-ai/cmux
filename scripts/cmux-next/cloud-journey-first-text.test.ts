import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FirstTextTiming, firstTextCommand, observeFirstText, probeRow, type Step } from "./cloud-journey";

const chunk = (kind = "agent_message_chunk", text = "hello") => ({
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
    await observeFirstText(async () => { throw new Error("transport closed"); }, "s", 5000, timing, (s) => steps.push(s));
    expect(steps[1]).toMatchObject({ status: "fail", detail: "transport closed" });
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
