// What the cheap model does with the room: fold pairs of memory nodes into short summaries, and
// read what was said since the last digest for asks that should become Chief tasks.

import type { Entry, MemoryNode, Summarize } from "./memory.ts";
import { entryLine } from "./memory.ts";
import type { Complete } from "./model.ts";

const SUMMARY_SYSTEM = `You compress a live meeting log for an AI's memory.
Write one summary of the two parts you are given, in plain sentences, at most 400 bytes.
Keep names, decisions, asks, numbers, file and product names. Drop filler and small talk.
Write only the summary.`;

export function modelSummarize(complete: Complete): Summarize {
  return async (left: MemoryNode, right: MemoryNode) => {
    const { text } = await complete({
      system: SUMMARY_SYSTEM,
      user: `Part A (entries ${left.start}+${left.n}):\n${left.text}\n\nPart B (entries ${right.start}+${right.n}):\n${right.text}`,
      maxTokens: 200,
    });
    return text.trim() || `${left.text}\n${right.text}`;
  };
}

export interface ProposedTask {
  /** 2-5 word title. */
  title: string;
  /** The ask in full, as a task brief. */
  ask: string;
  speaker: string;
  /** The words the ask came from, verbatim. */
  quote: string;
  /** The speaker spoke to the AI ("Chief, ...", "hey cmux ..."), not to another person. */
  addressed: boolean;
}

const TASK_SYSTEM = `You listen to a live room where people talk to each other and to an AI called Chief.
From the NEW lines only, list the concrete work asks: things someone wants done (build, fix, find,
send, check, write). Skip questions answered in the room, opinions, and jokes.
Set "addressed" true only when the speaker spoke to the AI ("Chief", "cmux", "hey AI", "can you").
Reply with JSON only: {"tasks":[{"title":"2-5 words","ask":"full brief","speaker":"name","quote":"exact words","addressed":true}]}
Reply {"tasks":[]} when there is none.`;

export function parseTasks(text: string): ProposedTask[] {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) return [];
  try {
    const parsed = JSON.parse(text.slice(start, end + 1)) as { tasks?: unknown };
    if (!Array.isArray(parsed.tasks)) return [];
    return parsed.tasks.flatMap((raw): ProposedTask[] => {
      if (!raw || typeof raw !== "object") return [];
      const task = raw as Record<string, unknown>;
      const title = typeof task.title === "string" ? task.title.trim() : "";
      const ask = typeof task.ask === "string" ? task.ask.trim() : "";
      if (!title || !ask) return [];
      return [
        {
          title,
          ask,
          speaker: typeof task.speaker === "string" ? task.speaker : "",
          quote: typeof task.quote === "string" ? task.quote : "",
          addressed: task.addressed === true,
        },
      ];
    });
  } catch {
    return [];
  }
}

export async function extractTasks(complete: Complete, view: string, fresh: Entry[]): Promise<ProposedTask[]> {
  const speech = fresh.filter((entry) => entry.kind === "speech" || entry.kind === "screen");
  if (!speech.some((entry) => entry.kind === "speech")) return [];
  const { text } = await complete({
    system: TASK_SYSTEM,
    user: `Room memory so far:\n${view || "(empty)"}\n\nNEW lines:\n${speech.map(entryLine).join("\n")}`,
    maxTokens: 600,
  });
  return parseTasks(text);
}
