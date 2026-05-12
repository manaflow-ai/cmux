/**
 * shell tool — run a shell command in the current working directory.
 */

import { z } from "zod";
import type { Tool, ToolContext, ToolEvent, ToolResult } from "../core/types";

const MAX_OUTPUT_BYTES = 200 * 1024; // 200 KB
const DEFAULT_TIMEOUT_MS = 120_000; // 120 seconds

const inputSchema = z.object({
  command: z.string(),
  cwd: z.string().optional(),
  timeout_ms: z.number().int().positive().max(600_000).optional(),
  env: z.record(z.string()).optional(),
});

type ShellInput = z.infer<typeof inputSchema>;

function truncateOutput(buf: Uint8Array): string {
  if (buf.byteLength <= MAX_OUTPUT_BYTES) {
    return new TextDecoder().decode(buf);
  }
  const half = Math.floor(MAX_OUTPUT_BYTES / 2);
  const trimmed = buf.byteLength - MAX_OUTPUT_BYTES;
  const head = new TextDecoder().decode(buf.slice(0, half));
  const tail = new TextDecoder().decode(buf.slice(buf.byteLength - half));
  return `${head}\n...(truncated ${trimmed} bytes)...\n${tail}`;
}

async function* runShell(
  input: ShellInput,
  ctx: ToolContext,
): AsyncIterable<ToolEvent> {
  const timeoutMs = input.timeout_ms ?? DEFAULT_TIMEOUT_MS;
  const cwd = input.cwd ?? ctx.cwd;

  let proc: ReturnType<typeof Bun.spawn> | undefined;
  let timedOut = false;
  let aborted = false;

  const kill = () => {
    if (proc && proc.exitCode === null) {
      try {
        proc.kill();
      } catch {
        // ignore
      }
    }
  };

  // Honor abort signal
  const onAbort = () => {
    aborted = true;
    kill();
  };
  ctx.abortSignal.addEventListener("abort", onAbort, { once: true });

  const timer = setTimeout(() => {
    timedOut = true;
    kill();
  }, timeoutMs);

  try {
    proc = Bun.spawn(["sh", "-c", input.command], {
      cwd,
      env: { ...process.env, ...(input.env ?? {}) },
      stdout: "pipe",
      stderr: "pipe",
    });

    const stdoutChunks: Uint8Array[] = [];
    const stderrChunks: Uint8Array[] = [];

    // Read stdout and stderr concurrently, streaming output_delta events
    const readStream = async (
      stream: ReadableStream<Uint8Array<ArrayBufferLike>>,
      chunks: Uint8Array[],
    ) => {
      const reader = stream.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        // yield as output_delta (text)
      }
    };

    // We need to interleave stream output with yielding ToolEvents.
    // Since generators can't easily await multiple things concurrently,
    // we collect both streams in parallel then yield results.
    const stdout = proc.stdout as ReadableStream<Uint8Array<ArrayBufferLike>>;
    const stderr = proc.stderr as ReadableStream<Uint8Array<ArrayBufferLike>>;

    const [stdoutResult, stderrResult] = await Promise.allSettled([
      readStream(stdout, stdoutChunks),
      readStream(stderr, stderrChunks),
    ]);

    // Yield output deltas for stdout
    for (const chunk of stdoutChunks) {
      yield { kind: "output_delta" as const, text: new TextDecoder().decode(chunk) };
    }
    // Yield output deltas for stderr
    for (const chunk of stderrChunks) {
      yield { kind: "output_delta" as const, text: new TextDecoder().decode(chunk) };
    }

    void stdoutResult; // results checked via chunks
    void stderrResult;

    const exitCode = await proc.exited;

    if (aborted) {
      const result: ToolResult = {
        content: "Command aborted by user.",
        isError: true,
      };
      yield { kind: "result" as const, result };
      return;
    }

    if (timedOut) {
      const result: ToolResult = {
        content: `Command timed out after ${timeoutMs}ms.`,
        isError: true,
      };
      yield { kind: "result" as const, result };
      return;
    }

    // Combine stdout and stderr
    const stdoutBuf = mergeChunks(stdoutChunks);
    const stderrBuf = mergeChunks(stderrChunks);

    let combined: string;
    if (stderrBuf.byteLength === 0) {
      combined = truncateOutput(stdoutBuf);
    } else if (stdoutBuf.byteLength === 0) {
      combined = truncateOutput(stderrBuf);
    } else {
      // Concatenate both, then truncate
      const total = new Uint8Array(stdoutBuf.byteLength + stderrBuf.byteLength);
      total.set(stdoutBuf, 0);
      total.set(stderrBuf, stdoutBuf.byteLength);
      const combinedRaw = truncateOutput(total);
      const stdoutStr = new TextDecoder().decode(stdoutBuf);
      const stderrStr = new TextDecoder().decode(stderrBuf);
      // Prefer to show separated output if it fits
      if (stdoutBuf.byteLength + stderrBuf.byteLength <= MAX_OUTPUT_BYTES) {
        combined = stderrStr
          ? `${stdoutStr}\n--- stderr ---\n${stderrStr}`
          : stdoutStr;
      } else {
        combined = combinedRaw;
      }
    }

    const content = `Exit code: ${exitCode}\n${combined}`;

    const result: ToolResult = {
      content,
      isError: exitCode !== 0,
    };
    yield { kind: "result" as const, result };
  } finally {
    clearTimeout(timer);
    ctx.abortSignal.removeEventListener("abort", onAbort);
  }
}

function mergeChunks(chunks: Uint8Array[]): Uint8Array {
  const total = chunks.reduce((sum, c) => sum + c.byteLength, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}

export const shellTool: Tool = {
  name: "shell",
  description:
    "Run a shell command in the current working directory. Returns combined stdout+stderr and the exit code.",
  inputSchema,
  defaultPermission: "ask",
  run(input: unknown, ctx: ToolContext): AsyncIterable<ToolEvent> {
    const parsed = inputSchema.parse(input);
    return runShell(parsed, ctx);
  },
};
