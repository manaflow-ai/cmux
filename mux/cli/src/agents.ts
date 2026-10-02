import { AcpmuxClient, retryAgentStart, type SessionSummary } from "@mux/acpmux";
import { PARENT_TAG } from "./supervisor.ts";

/** The mux session agents report to. */
export const MUX_SESSION = process.env.MUX_SESSION_NAME ?? "mux";

export async function acpmuxCli(args: string[]): Promise<string> {
  const child = Bun.spawn(["acpmux", ...args], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const [out, err, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (code !== 0)
    throw new Error(
      `acpmux ${args.join(" ")} failed (${code}): ${(err || out).trim().slice(0, 300)}`,
    );
  return out;
}

export async function lastReply(sessionId: string): Promise<string> {
  const out = await acpmuxCli(["--json", "last", sessionId]).catch(() => "{}");
  const replies = (JSON.parse(out) as { replies?: string[] }).replies ?? [];
  return replies.at(-1) ?? "";
}

/**
 * Starts an agent for the mux: a tagged acpmux session with its first prompt.
 * Returns once the prompt is accepted (the agent is running); its turn
 * continues in acpmux and its end comes back to the mux as an event.
 */
export async function spawnAgent(options: {
  cwd: string;
  prompt: string;
  name?: string;
  harness?: string;
  policy?: string;
  parent?: string;
}): Promise<SessionSummary> {
  const client = await AcpmuxClient.connect();
  try {
    const { sessionId } = await retryAgentStart(async () => {
      // A start that failed still leaves the named session; reuse it.
      const existing = options.name
        ? (await client.sessions()).find((s) => s.name === options.name)
        : undefined;
      return existing ? { sessionId: existing.sessionId } : client.newSession(options);
    });
    const tagged = await client.tag(sessionId, { [PARENT_TAG]: options.parent ?? MUX_SESSION });
    await client.watch(true);
    const running = new Promise<void>((resolve) => {
      const stop = client.onNotification((n) => {
        const session = n.params.session as SessionSummary | undefined;
        if (
          n.method === "_acpmux/session_changed" &&
          session?.sessionId === sessionId &&
          session.status === "running"
        ) {
          stop();
          resolve();
        }
      });
    });
    void client.prompt(sessionId, options.prompt).catch(() => undefined);
    await Promise.race([running, new Promise((resolve) => setTimeout(resolve, 15_000))]);
    return tagged;
  } finally {
    client.close();
  }
}

export async function listAgents(parent = MUX_SESSION): Promise<SessionSummary[]> {
  const client = await AcpmuxClient.connect();
  try {
    return (await client.sessions()).filter((s) => s.tags?.[PARENT_TAG] === parent);
  } finally {
    client.close();
  }
}
