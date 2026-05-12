import { tmpdir } from "os";
import type { HookConfig, HookEvent, HookResponse, Config } from "@/core/types";

export { tmpdir }; // re-export for tests

type LogLevel = "debug" | "info" | "warn" | "error";
type Logger = (level: LogLevel, msg: string) => void;

export const HOOK_TIMEOUT_MS = 10_000;

export class HookRegistry {
  private hooks: HookConfig[];
  readonly log: Logger;

  constructor(hooks: HookConfig[], log: Logger) {
    this.hooks = hooks;
    this.log = log;
  }

  /**
   * Returns true if the hook applies to the given event data.
   * If the hook has a `matcher` regex, it is tested against JSON.stringify(eventData).
   */
  setMatcher(hook: HookConfig, eventData: unknown): boolean {
    if (!hook.matcher) return true;
    try {
      const re = new RegExp(hook.matcher);
      return re.test(JSON.stringify(eventData));
    } catch {
      this.log("warn", `Hook matcher "${hook.matcher}" is not a valid regex; skipping hook`);
      return false;
    }
  }

  async fire(event: HookEvent): Promise<HookResponse> {
    const matching = this.hooks.filter(
      (h) => h.event === event.event && this.setMatcher(h, event.data),
    );

    let currentData: unknown = event.data;

    for (const hook of matching) {
      const payload: HookEvent = { ...event, data: currentData };
      const payloadJson = JSON.stringify(payload);

      const response = await this.runHook(hook, event, payloadJson);

      if (response.action === "block") {
        return response;
      }

      if (response.action === "transform") {
        currentData = response.data;
      }
      // "pass" => currentData unchanged, continue
    }

    return { action: "pass", data: currentData };
  }

  /** Exposed for subclass overrides in tests. */
  protected async runHook(
    hook: HookConfig,
    event: HookEvent,
    payloadJson: string,
    timeoutMs: number = HOOK_TIMEOUT_MS,
  ): Promise<HookResponse> {
    const env: Record<string, string> = Object.assign(
      {},
      process.env as Record<string, string>,
      {
        CMUX101_HOOK_EVENT: event.event,
        CMUX101_SESSION_ID: event.sessionId,
      },
    );

    let proc: ReturnType<typeof Bun.spawn>;
    try {
      proc = Bun.spawn(["sh", "-c", hook.command], {
        stdin: "pipe",
        stdout: "pipe",
        stderr: "pipe",
        env,
      });
    } catch (err) {
      this.log("warn", `Hook spawn failed for "${hook.command}": ${err}; treating as pass`);
      return { action: "pass" };
    }

    // Write payload to stdin then close it.
    // Bun's FileSink (proc.stdin when stdin:"pipe") uses write() + end().
    const stdin = proc.stdin as import("bun").FileSink;
    stdin.write(payloadJson);
    await stdin.end();

    // Race the process exit against a timeout.
    let timedOut = false;
    const timeoutId = setTimeout(() => {
      timedOut = true;
      try { proc.kill(); } catch { /* ignore */ }
    }, timeoutMs);

    try {
      await proc.exited;
    } finally {
      clearTimeout(timeoutId);
    }

    if (timedOut) {
      this.log("warn", `Hook "${hook.command}" timed out after ${timeoutMs}ms; treating as pass`);
      return { action: "pass" };
    }

    // Read stdout
    const stdoutRaw = proc.stdout;
    let stdoutText = "";
    if (stdoutRaw && typeof stdoutRaw !== "number") {
      stdoutText = await new Response(stdoutRaw as BodyInit).text();
    }

    try {
      const parsed = JSON.parse(stdoutText.trim()) as HookResponse;
      if (
        parsed.action === "pass" ||
        parsed.action === "block" ||
        parsed.action === "transform"
      ) {
        return parsed;
      }
      throw new Error(`Unknown action: ${String(parsed.action)}`);
    } catch (err) {
      this.log(
        "warn",
        `Hook "${hook.command}" returned non-JSON or invalid response: ${err}; treating as pass`,
      );
      return { action: "pass" };
    }
  }
}

export async function loadHooksFromConfig(config: Config): Promise<HookRegistry> {
  const hooks = config.hooks ?? [];
  const log: Logger = (level, msg) => {
    const prefix = `[hooks][${level}]`;
    if (level === "error" || level === "warn") {
      console.error(prefix, msg);
    } else {
      console.log(prefix, msg);
    }
  };
  return new HookRegistry(hooks, log);
}
