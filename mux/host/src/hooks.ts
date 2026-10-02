import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { type FileMemoryStore, toLines, wake } from "../../packages/brain/src/index.ts";
import { EVENT_PREFIX } from "./supervisor.ts";

// Claude Code memory hooks for the mux. Ported from feat-mux mux/cli/src/hooks.ts
// with the same semantics: session-start shows the wake view, user-prompt-submit
// logs the prompt and shows other sessions' news, stop logs the reply.

/** The Claude Code hook input fields mux reads. */
export interface HookInput {
  session_id: string;
  hook_event_name?: string;
  transcript_path?: string;
  source?: string;
  prompt?: string;
  last_assistant_message?: string;
}

export interface HookOutput {
  hookSpecificOutput: { hookEventName: string; additionalContext: string };
}

export interface HookContext {
  store: FileMemoryStore;
  sessionsDir: string;
  /** Lines of memory shown at session start (OptMem's WAKE_LINES). */
  budget: number;
  now?: Date;
}

/** Longest reply kept in the log; summaries and recall cover the gist. */
const MAX_REPLY_LINES = 4;
const MAX_PROMPT_LINES = 8;

const tag = (sessionID: string) => `[${sessionID.slice(0, 8)}]`;
const stamp = (now = new Date()) => now.toISOString().slice(0, 16);

/** How far into the log a session has seen; new lines past it come from other sessions. */
function seen(ctx: HookContext, sessionID: string): number {
  const file = join(ctx.sessionsDir, `${sessionID}.json`);
  if (!existsSync(file)) return 0;
  return (JSON.parse(readFileSync(file, "utf8")) as { seen: number }).seen;
}

function setSeen(ctx: HookContext, sessionID: string, value: number): void {
  writeFileSync(join(ctx.sessionsDir, `${sessionID}.json`), JSON.stringify({ seen: value }));
}

function context(event: string, text: string): HookOutput {
  return { hookSpecificOutput: { hookEventName: event, additionalContext: text } };
}

/**
 * The wake view, capped: summaries that compaction has not built yet show as
 * their children, so before compaction catches up the view can be long. Past
 * twice the budget, only the newest lines are shown.
 */
export async function renderWake(
  store: FileMemoryStore,
  budget: number,
): Promise<{ text: string; missing: number }> {
  const view = await wake(store, budget);
  const lines = view.text ? view.text.split("\n") : [];
  if (lines.length <= budget * 2) return { text: view.text, missing: view.missing.length };
  const kept = lines.slice(-budget * 2);
  const note = `(${lines.length - kept.length} older entries are not summarized yet; use \`mux memory recall\`.)`;
  return { text: [note, ...kept].join("\n"), missing: view.missing.length };
}

/** SessionStart (startup, resume, clear, compact): the memory view. */
export async function sessionStart(ctx: HookContext, input: HookInput): Promise<HookOutput> {
  const { text } = await renderWake(ctx.store, ctx.budget);
  setSeen(ctx, input.session_id, await ctx.store.length());
  const body = text || "(empty: this is your first session)";
  return context(
    "SessionStart",
    `<mux-memory>\nYour long-term memory (#n is a log line, #a-b a summary of lines a..b; newest last):\n${body}\n</mux-memory>`,
  );
}

/** UserPromptSubmit: log the message; show what other sessions added since this one last looked. */
export async function userPromptSubmit(
  ctx: HookContext,
  input: HookInput,
): Promise<HookOutput | undefined> {
  const store = ctx.store;
  const from = seen(ctx, input.session_id);
  const length = await store.length();
  const mine = tag(input.session_id);
  const news = (await store.read(from, length))
    .map((line, i) => ({ line, index: from + i }))
    .filter(({ line }) => !line.includes(mine));
  // Supervisor prompts (agent events) are logged as events, not as the user's words.
  const prompt = input.prompt ?? "";
  const event = prompt.startsWith(EVENT_PREFIX);
  const body = event ? prompt.slice(EVENT_PREFIX.length).trim() : prompt;
  const lines = toLines(`${stamp(ctx.now)} ${mine} ${event ? "event" : "user"}: ${body}`).slice(
    0,
    MAX_PROMPT_LINES,
  );
  setSeen(ctx, input.session_id, await store.append(lines));
  store.commit("prompt");
  if (news.length === 0) return undefined;
  const shown = news.slice(-ctx.budget).map(({ line, index }) => `#${index} ${line}`);
  return context(
    "UserPromptSubmit",
    `<mux-memory-update>\nNew in your memory from other sessions:\n${shown.join("\n")}\n</mux-memory-update>`,
  );
}

/** Stop: log the reply. Returns whether compaction has work to do. */
export async function stop(ctx: HookContext, input: HookInput): Promise<{ compact: boolean }> {
  const reply = input.last_assistant_message ?? lastAssistantText(input.transcript_path);
  if (reply) {
    const lines = toLines(`${stamp(ctx.now)} ${tag(input.session_id)} mux: ${reply}`).slice(
      0,
      MAX_REPLY_LINES,
    );
    setSeen(ctx, input.session_id, await ctx.store.append(lines));
    ctx.store.commit("reply");
  }
  const { missing } = await wake(ctx.store, ctx.budget);
  return { compact: missing.length > 0 };
}

/** The last assistant text in a Claude Code transcript (JSONL). */
export function lastAssistantText(transcriptPath: string | undefined): string | undefined {
  if (!transcriptPath || !existsSync(transcriptPath)) return undefined;
  const lines = readFileSync(transcriptPath, "utf8").trimEnd().split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const entry = JSON.parse(lines[i]) as { type?: string; message?: { content?: unknown } };
      if (entry.type !== "assistant" || !Array.isArray(entry.message?.content)) continue;
      const text = (entry.message.content as { type?: string; text?: string }[])
        .filter((part) => part.type === "text" && part.text)
        .map((part) => part.text)
        .join("\n")
        .trim();
      if (text) return text;
    } catch {
      // A partial last line while Claude Code is writing; skip it.
    }
  }
  return undefined;
}
