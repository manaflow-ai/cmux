import { compact, type FileMemoryStore, SUMMARY_INSTRUCTIONS, type Summarize, wake } from "../../packages/brain/src/index.ts";
import { AcpmuxClient, eventFromUpdate } from "./acpmux-client.ts";
import { TurnFolder } from "./turns.ts";

/**
 * Builds the summaries the wake view needs, in bounded steps, until none are
 * missing or a step makes no progress (feat-mux mux/cli/src/compactor.ts).
 */
export async function compactUntilDone(store: FileMemoryStore, budget: number, summarize: Summarize): Promise<number> {
  let total = 0;
  for (;;) {
    const { missing } = await wake(store, budget);
    if (missing.length === 0) return total;
    const written = await compact(store, missing, summarize, 8);
    store.commit(`compact ${written}`);
    total += written;
    if (written === 0) return total;
  }
}

/**
 * Runs one prompt on an acpmux session and returns its reply text: attaches
 * for the session's events, prompts, folds agent_message_chunk until the
 * prompt's turn ends (the prompt reply), all event-driven.
 */
export async function runTurn(client: AcpmuxClient, sessionId: string, text: string): Promise<string> {
  const attached = await client.attach(sessionId, 0, 1);
  const id = attached.session.sessionId;
  const folder = new TurnFolder(attached.session.lastSeq ?? 0);
  const promptId = `compact-${crypto.randomUUID()}`;
  let reply = "";
  let mine = false;
  const stop = client.onNotification((n) => {
    if (n.params.sessionId !== id) return;
    const event =
      n.method === "_acpmux/event"
        ? (n.params as unknown as Parameters<TurnFolder["apply"]>[0])
        : n.method === "session/update"
          ? eventFromUpdate(n.params)
          : undefined;
    if (!event) return;
    for (const out of folder.apply(event)) {
      if (out.type === "started") mine = out.turn.promptId === promptId;
      if (out.type === "ended" && mine) reply = out.turn.text;
    }
  });
  try {
    await client.prompt(id, text, { promptId, delivery: "turn" });
    return reply.trim();
  } finally {
    stop();
  }
}

/**
 * A summarizer on a cheap acpmux agent (default harness `claude`, model
 * `haiku`, deny-all). One session per compactor run, purged when it ends.
 */
export async function acpmuxSummarizer(
  cwd: string,
  harness: string,
  model: string | undefined,
): Promise<{ summarize: Summarize; close: () => Promise<void> }> {
  const client = await AcpmuxClient.connect(undefined, "mux-compactor");
  const { sessionId } = await client.newSession({
    cwd,
    name: `mux-compactor-${process.pid}`,
    harness,
    model,
    policy: "deny-all",
  });
  return {
    summarize: ({ left, right }) =>
      runTurn(client, sessionId, `${SUMMARY_INSTRUCTIONS}\nReply with the merged line only.\n\nA: ${left}\nB: ${right}`),
    close: async () => {
      await client.kill(sessionId, true).catch(() => undefined);
      client.close();
    },
  };
}
