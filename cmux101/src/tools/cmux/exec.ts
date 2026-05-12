/**
 * exec.ts — shared helper for running cmux CLI commands.
 *
 * All cmux tools call runCmux() rather than spawning directly, so timeout
 * handling, error normalisation, and the CMUX_WORKSPACE_ID env default live
 * in one place.
 */

const DEFAULT_TIMEOUT_MS = 30_000;

export interface CmuxResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

/**
 * Run `cmux <args>` with piped stdout/stderr.
 *
 * Inherits the current process environment so CMUX_SOCKET_PATH,
 * CMUX_WORKSPACE_ID, etc. are forwarded automatically.
 */
export async function runCmux(
  args: string[],
  opts?: { timeoutMs?: number },
): Promise<CmuxResult> {
  const timeoutMs = opts?.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  const proc = Bun.spawn(["cmux", ...args], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env },
  });

  // Kill after timeout
  const timer = setTimeout(() => {
    try {
      proc.kill();
    } catch {
      // ignore
    }
  }, timeoutMs);

  try {
    const [stdoutBuf, stderrBuf, exitCode] = await Promise.all([
      readAll(proc.stdout),
      readAll(proc.stderr),
      proc.exited,
    ]);

    return {
      stdout: new TextDecoder().decode(stdoutBuf),
      stderr: new TextDecoder().decode(stderrBuf),
      exitCode,
    };
  } finally {
    clearTimeout(timer);
  }
}

async function readAll(stream: ReadableStream<Uint8Array>): Promise<Uint8Array> {
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }
  const total = chunks.reduce((sum, c) => sum + c.byteLength, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}
