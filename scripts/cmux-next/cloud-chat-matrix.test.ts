import { expect, test } from "bun:test";
import { CELLS, PICKER_HARNESSES, appStartDetail, judge, table } from "./cloud-chat-matrix";
import { JOURNEY_ONLY_STEPS } from "./cloud-journey";

const cell = (id: string) => CELLS.find((c) => c.id === id)!;
const pass = (step: string, ms = 1000, detail = "") => ({ step, status: "pass" as const, ms, detail });
const fail = (step: string, ms: number, detail: string) => ({ step, status: "fail" as const, ms, detail });

test("a cell passes only when every step did, and reports its timings", () => {
  const steps = [pass("create machine", 3000), pass("reply", 1034, "Stub reply abc."), pass("turn 2 (same session)", 5060), pass("pause", 1965), pass("resume", 3174), pass("turn after resume", 6984)];
  const row = judge(cell("codex-chatgpt-stub"), steps, 0);
  expect(row.verdict).toBe("pass");
  expect(row.ms).toEqual({ "create machine": 3000, reply: 1034, "turn 2 (same session)": 5060, pause: 1965, resume: 3174, "turn after resume": 6984 });
  expect(judge(cell("codex-chatgpt-stub"), [...steps, fail("delete", 10, "gone?")], 1).verdict).toBe("fail");
  // The journey's own summary line is not a step failure.
  expect(judge(cell("codex-chatgpt-stub"), [...steps, fail("prod: 6 passed, 0 failed", 0, "")], 0).verdict).toBe("pass");
});

test("a hung Codex reply is a failure that names the step", () => {
  const row = judge(cell("codex-model-plane"), [pass("start agent (codex)"), fail("reply", 305357, "no reply within 300 s; last: ")], 1);
  expect(row.verdict).toBe("fail");
  expect(row.why).toStartWith("reply: no reply within 300 s");
});

test("the live Codex GitHub cell uses the ChatGPT auth row", () => {
  const c = cell("codex-github-live");
  expect(c.agent).toBe("codex");
  expect(c.args).toEqual(["--agent", "codex"]);
  expect(c.needs?.env).toEqual(["CODEX_AUTH_JSON", "CMUX_JOURNEY_GITHUB_REPO"]);
  // Its proof steps are the journey's own names.
  for (const name of c.must ?? []) expect(JOURNEY_ONLY_STEPS as readonly string[]).toContain(name);
});

test("the live GitHub cell fails, never passes, when its GitHub steps were skipped", () => {
  const c = cell("codex-github-live");
  const chat = [pass("create machine"), pass("reply", 1000, "ok")];
  const skipped = { step: "GitHub by the agent (live)", status: "skip" as const, ms: 0, detail: "CMUX_JOURNEY_GITHUB_REPO is not set" };
  const row = judge(c, [...chat, pass("GitHub on the machine (live)"), skipped], 0);
  expect(row.verdict).toBe("fail");
  expect(row.why).toBe("GitHub by the agent (live) did not run: CMUX_JOURNEY_GITHUB_REPO is not set");
  expect(judge(c, chat, 0).why).toBe("GitHub on the machine (live) did not run: not run");
  expect(judge(c, [...chat, pass("GitHub on the machine (live)"), pass("GitHub by the agent (live)")], 0).verdict).toBe("pass");
});

test("a signed-out agent passes only by failing fast with its sign-in error", () => {
  const c = cell("gemini-signed-out");
  expect(judge(c, [pass("start agent (gemini)"), fail("reply", 2100, "acp wait exit 1: Authentication required")], 1).verdict).toBe("pass");
  // Not installed is not signed out.
  const missing = judge(c, [fail("start agent (gemini)", 1193, 'unknown harness "gemini"')], 1);
  expect(missing.verdict).toBe("fail");
  expect(missing.why).toContain("unknown harness");
  // A hang is not a refusal, nor is a refusal that took too long.
  expect(judge(c, [pass("start agent (gemini)"), fail("reply", 120_000, "no reply within 120 s; last: ")], 1).verdict).toBe("fail");
  expect(judge(c, [pass("start agent (gemini)"), fail("reply", 90_000, "Authentication required")], 1).verdict).toBe("fail");
  // A reply where a refusal belongs is a failure too.
  expect(judge(c, [pass("start agent (gemini)"), pass("reply", 900, "Earth")], 0).verdict).toBe("fail");
});

test("no cell needs an account Leo does not have", () => {
  // cursor and grok appear only as app-start cells, which pass signed out by naming the harness.
  expect(CELLS.filter((c) => c.agent === "cursor" || c.agent === "grok").every((c) => c.proof === "start")).toBe(true);
});

test("every picker harness has an app-start cell over the app's start path", () => {
  expect(CELLS.filter((c) => c.proof === "start").map((c) => c.agent)).toEqual([...PICKER_HARNESSES]);
  for (const h of PICKER_HARNESSES) {
    const c = cell(`${h}-app-start`);
    expect(c.args).toEqual(["--agent", h, "--start-via", "app", "--cmux", "$CMUX_BIN"]);
    expect(c.needs?.env).toBe("CMUX_BIN");
  }
});

test("an app-start cell passes on a session or on sign_in_required naming its own harness, nothing else", () => {
  const c = cell("grok-app-start");
  const start = "start agent (grok)";
  const machine = pass("create machine", 3000);
  const started = appStartDetail({ ok: true, data: { session: "s-1" } });
  expect(started).toEqual({ ok: true, detail: "started: session s-1" });
  expect(judge(c, [machine, pass(start, 900, started.detail)], 0).verdict).toBe("pass");
  const signedOut = appStartDetail({ ok: false, error_code: "agent_session.sign_in_required", error: { message: "the agent is not signed in" }, data: { reason: "agent.sign_in_required", harness: "grok", errorKind: "auth.signed_out" } });
  expect(signedOut.ok).toBe(false);
  const row = judge(c, [machine, fail(start, 1200, signedOut.detail)], 1);
  expect(row.verdict).toBe("pass");
  expect(row.why).toContain("named grok");
  // Another harness's name, no name, or the bare refusal is a failure.
  const other = appStartDetail({ ok: false, error_code: "agent_session.sign_in_required", data: { harness: "cursor" } });
  expect(judge(c, [machine, fail(start, 1200, other.detail)], 1).verdict).toBe("fail");
  const unnamed = appStartDetail({ ok: false, error_code: "agent_session.sign_in_required", data: { reason: "agent.sign_in_required" } });
  expect(judge(c, [machine, fail(start, 1200, unnamed.detail)], 1).verdict).toBe("fail");
  const bare = appStartDetail({ ok: false, error_code: "agent_session.refused", error: { message: "Authentication required" } });
  const refused = judge(c, [machine, fail(start, 1200, bare.detail)], 1);
  expect(refused.verdict).toBe("fail");
  expect(refused.why).toContain("agent_session.refused");
  // A start with no session, an earlier failure, or a start that never ran fails too.
  expect(judge(c, [machine, fail(start, 10, appStartDetail({ ok: true, data: {} }).detail)], 1).verdict).toBe("fail");
  expect(judge(c, [fail("create machine", 5000, "quota"), fail(start, 1200, signedOut.detail)], 1).verdict).toBe("fail");
  expect(judge(c, [machine], 1).verdict).toBe("fail");
});

test("the table has one row per cell and escapes pipes", () => {
  const rows = [judge(cell("codex-model-plane"), [fail("reply", 1, "a | b")], 1)];
  const md = table(rows);
  expect(md.split("\n")).toHaveLength(3);
  expect(md).toContain("a \\| b");
});

test("OpenCode on Zen runs every turn; signed-out Gemini passes only by refusing fast", () => {
  const steps = [pass("create machine", 5507), pass("reply", 2849, "pong"), pass("turn 2 (same session)", 2862), pass("pause", 1687), pass("resume", 1267), pass("turn after resume", 4118)];
  expect(judge(cell("opencode-zen"), steps, 0).verdict).toBe("pass");
  expect(cell("opencode-zen").args).toContain("--lifecycle");
  for (const id of ["gemini-signed-out"]) {
    const c = cell(id);
    expect(judge(c, [pass(`start agent (${c.agent})`), fail("reply", 900, "acp wait exit 1: Authentication required")], 1).verdict).toBe("pass");
    expect(judge(c, [fail(`start agent (${c.agent})`, 1193, `unknown harness "${c.agent}"`)], 1).verdict).toBe("fail");
    expect(judge(c, [pass(`start agent (${c.agent})`), fail("reply", 120_000, "no reply within 120 s; last: ")], 1).verdict).toBe("fail");
  }
});
