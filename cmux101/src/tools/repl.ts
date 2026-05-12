/**
 * repl tool — persistent Python or Node REPL subprocess per session.
 *
 * State (the subprocess) lives in a module-level Map keyed by session ID so
 * each session gets its own isolated REPL that persists across tool calls.
 */

import { z } from "zod";
import type { Tool, ToolContext, ToolResult } from "../core/types";

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

const inputSchema = z.object({
  language: z.enum(["python", "node"]),
  code: z.string(),
});

type ReplInput = z.infer<typeof inputSchema>;

// ---------------------------------------------------------------------------
// REPL state
// ---------------------------------------------------------------------------

interface ReplState {
  language: "python" | "node";
  proc: ReturnType<typeof Bun.spawn>;
  sink: import("bun").FileSink;
  stdoutBuffer: string;
  stderrBuffer: string;
}

// Module-level map: sessionId -> ReplState
const sessions = new Map<string, ReplState>();

const SENTINEL = "___CMUX_END___";
const TIMEOUT_MS = 30_000;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function spawnRepl(language: "python" | "node"): ReplState {
  const cmd =
    language === "python"
      ? ["python3", "-i", "-q"]
      : ["node", "-i"];

  const proc = Bun.spawn(cmd, {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  const sink = proc.stdin as import("bun").FileSink;

  const state: ReplState = {
    language,
    proc,
    sink,
    stdoutBuffer: "",
    stderrBuffer: "",
  };

  // Drain stdout and stderr into buffers continuously
  drainStream(proc.stdout as ReadableStream<Uint8Array>, state, "stdout");
  drainStream(proc.stderr as ReadableStream<Uint8Array>, state, "stderr");

  return state;
}

async function drainStream(
  stream: ReadableStream<Uint8Array>,
  state: ReplState,
  which: "stdout" | "stderr"
): Promise<void> {
  const reader = stream.getReader();
  const dec = new TextDecoder();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (which === "stdout") {
        state.stdoutBuffer += dec.decode(value);
      } else {
        state.stderrBuffer += dec.decode(value);
      }
    }
  } catch {
    // stream closed
  }
}

function isAlive(state: ReplState): boolean {
  return state.proc.exitCode === null;
}

async function sendCode(
  state: ReplState,
  code: string,
  abortSignal: AbortSignal
): Promise<{ stdout: string; stderr: string; timedOut: boolean; aborted: boolean }> {
  const enc = new TextEncoder();

  // Wrap code to print sentinel after execution
  let wrapped: string;
  if (state.language === "python") {
    // Use exec() so multi-line code works; print sentinel after
    const escaped = code.replace(/\\/g, "\\\\").replace(/"""/g, '\\"\\"\\"');
    wrapped = `exec("""${escaped}""")\nprint("${SENTINEL}")\n`;
  } else {
    // Node: eval the code then log sentinel
    wrapped = `${code}\nconsole.log("${SENTINEL}")\n`;
  }

  // Snapshot current buffer lengths to slice new output from
  const stdoutStart = state.stdoutBuffer.length;
  const stderrStart = state.stderrBuffer.length;

  // Write to stdin
  try {
    state.sink.write(enc.encode(wrapped));
    await state.sink.flush();
  } catch (err) {
    return {
      stdout: "",
      stderr: `Failed to write to REPL stdin: ${String(err)}`,
      timedOut: false,
      aborted: false,
    };
  }

  // Poll for sentinel in stdout
  const deadline = Date.now() + TIMEOUT_MS;
  let timedOut = false;
  let aborted = false;

  while (true) {
    if (abortSignal.aborted) {
      aborted = true;
      break;
    }
    const elapsed = Date.now();
    if (elapsed >= deadline) {
      timedOut = true;
      break;
    }

    const currentOut = state.stdoutBuffer.slice(stdoutStart);
    if (currentOut.includes(SENTINEL)) {
      break;
    }

    await Bun.sleep(20);
  }

  const stdout = state.stdoutBuffer
    .slice(stdoutStart)
    .replace(new RegExp(`.*${SENTINEL}.*\n?`, "g"), "")
    .trimEnd();
  const stderr = state.stderrBuffer.slice(stderrStart).trimEnd();

  return { stdout, stderr, timedOut, aborted };
}

// ---------------------------------------------------------------------------
// Tool run
// ---------------------------------------------------------------------------

async function runRepl(input: ReplInput, ctx: ToolContext): Promise<ToolResult> {
  if (ctx.abortSignal.aborted) {
    return { content: "Aborted.", isError: true };
  }

  const sessionId = ctx.session.meta.id;
  const stateKey = `${sessionId}:${input.language}`;

  let state = sessions.get(stateKey);

  // Spawn or restart if dead
  if (!state || !isAlive(state)) {
    if (state) {
      // Clean up dead state
      try { state.proc.kill(); } catch { /* ignore */ }
      sessions.delete(stateKey);
    }
    state = spawnRepl(input.language);
    sessions.set(stateKey, state);
  }

  const finalState = state;

  // Kill on abort
  const onAbort = () => {
    try { finalState.proc.kill(); } catch { /* ignore */ }
    sessions.delete(stateKey);
  };
  ctx.abortSignal.addEventListener("abort", onAbort, { once: true });

  try {
    const { stdout, stderr, timedOut, aborted } = await sendCode(
      state,
      input.code,
      ctx.abortSignal
    );

    if (aborted) {
      return { content: "REPL aborted.", isError: true };
    }

    if (timedOut) {
      // Kill the stuck REPL so next call gets a fresh one
      try { state.proc.kill(); } catch { /* ignore */ }
      sessions.delete(stateKey);
      return {
        content: `REPL timed out after ${TIMEOUT_MS / 1000}s. Subprocess killed.`,
        isError: true,
      };
    }

    const parts: string[] = [];
    if (stdout) parts.push(stdout);
    if (stderr) parts.push(`[stderr]\n${stderr}`);
    const output = parts.join("\n").trim();

    return { content: output || "(no output)" };
  } finally {
    ctx.abortSignal.removeEventListener("abort", onAbort);
  }
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

export const replTool: Tool = {
  name: "repl",
  description:
    "Run code in a persistent Python or Node.js REPL. State is shared across calls within the same session — define a variable in one call and use it in the next.",
  inputSchema,
  defaultPermission: "ask",

  async run(input: unknown, ctx: ToolContext): Promise<ToolResult> {
    const parsed = inputSchema.parse(input);
    return runRepl(parsed, ctx);
  },
};

/**
 * Exported for testing: forcibly clear all REPL sessions.
 */
export function clearReplSessions(): void {
  for (const state of sessions.values()) {
    try { state.proc.kill(); } catch { /* ignore */ }
  }
  sessions.clear();
}
