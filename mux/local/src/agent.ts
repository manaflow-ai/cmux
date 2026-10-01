// The local mux's brain: one acpmux session per conversation. acpmux keeps the
// session alive and its context; this module only ensures it and sends turns.

export interface AgentOptions {
  harness: string;
  policy: string;
  cwd: string;
}

export interface AgentRunner {
  /** Sends one prompt to the conversation's session and returns the final reply text. */
  send(session: string, prompt: string): Promise<string>;
  ensure(session: string): Promise<void>;
}

async function acpmux(args: string[], stdin?: string): Promise<string> {
  const child = Bun.spawn(["acpmux", ...args], {
    stdin: stdin === undefined ? "ignore" : new Blob([stdin]),
    stdout: "pipe",
    stderr: "pipe",
  });
  const [out, err, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (code !== 0)
    throw new Error(`acpmux ${args[0]} failed (${code}): ${(err || out).trim().slice(0, 400)}`);
  return out;
}

/**
 * Runs `attempt` again when the agent process closed while starting: the
 * subrouter launcher (claude-sr) checks Tailscale at start, and that check
 * can be killed on a busy machine. acpmux keeps the session, so the retry
 * starts its agent again.
 */
export async function retryAgentStart<T>(attempt: () => Promise<T>, attempts = 3): Promise<T> {
  for (let i = 1; ; i++) {
    try {
      return await attempt();
    } catch (error) {
      if (i >= attempts || !String(error).includes("agent process closed")) throw error;
    }
  }
}

export function acpmuxRunner(options: AgentOptions): AgentRunner {
  const create = [
    "-m",
    options.harness,
    "--cwd",
    options.cwd,
    "--policy",
    options.policy,
    "--json",
  ];
  return {
    async ensure(session) {
      await retryAgentStart(() => acpmux(["ensure", session, ...create]));
    },
    async send(session, prompt) {
      return (
        await retryAgentStart(() => acpmux(["send", session, "-q", "--stall", "0", "-"], prompt))
      ).trim();
    },
  };
}

/** acpmux session names: `mux-` plus the conversation id's first block. */
export function sessionName(conversationId: string): string {
  return `mux-${conversationId.split("-")[0]}`;
}

export function firstPrompt(input: { memoryDir: string; memory: string; title: string }): string {
  return [
    `You are mux, the user's orchestrator agent, talking in a Messages-style chat ("${input.title}") inside cmux.`,
    "Reply like a capable colleague texting: short, direct, plain text, no headings.",
    "You run on the user's Mac as an acpmux session. Do real work: start and steer other coding agents with",
    'the acpmux CLI (`acpmux new -m claude --cwd DIR -d "prompt"`, `acpmux ls`, `acpmux last NAME`, `acpmux send NAME "text"`),',
    "and use the shell when that is quicker. Say what you started and what happens next.",
    `Your memory is the append-only log ${input.memoryDir}/LOG.txt (a git repo); every message is recorded there.`,
    "grep it for anything older than what is shown below. Never edit it by hand.",
    input.memory ? `\nRecent memory:\n${input.memory}` : "",
  ]
    .filter(Boolean)
    .join("\n");
}
