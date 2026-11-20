// "Continue in my own chat" (Leo, 2026-11-03, on a teammate in a chat shared from a personal subscription:
// they press "continue in my own session", which copies the context into a session on their own login, and
// their prompt never runs on the owner's plan: "i think that's entirely fair"). The guest page turns what
// this guest can already see of the shared chat into one self-contained message: who said what, in order,
// each person's turn under their own name. The guest pastes it into a new chat in their own cmux, where it
// runs on their sign-in. Nothing here reaches the room or the owner: the text is built from the rows the
// room already sent this page, and a tool line is its title only, as the app's own Markdown copy keeps it.
import type { AcpmuxRow } from "../acpmux/model";

/** The most a continuation carries, in UTF-8 bytes: the app's Continue In capsule bound. */
export const CONTINUE_LIMIT_BYTES = 65_536;

export type ContinueSource = {
  /** The chat's title, when the room named one. */
  title?: string;
  /** The owner's name, for their own prompts (which carry no author). */
  owner: string;
  /** The share page without its secret: where this came from, never a way in. */
  page: string;
  /** What to call the agent's turns. */
  agent: string;
  /** The heading lines (already translated): the intro naming the owner and page, and the cut note. */
  intro: string;
  /** Said in place of the turns the bound left out (oldest first). */
  cut: string;
};

const encoder = new TextEncoder();
const bytes = (text: string) => encoder.encode(text).length;

const body = (row: AcpmuxRow) => row.text?.trim() ?? "";
/** A prompt the agent got (the app's copyRow.ts `sent`). */
const sent = (row: AcpmuxRow) =>
  row.kind === "user" && !row.pending && !row.failed && !row.queued && row.incoming?.kind !== "hidden";

/** One person's or the agent's turn per block, each under its author's name. */
export function continueBlocks(rows: readonly AcpmuxRow[], owner: string, agent: string): string[] {
  const blocks: string[] = [];
  for (const row of rows) {
    const text = body(row);
    if (sent(row)) {
      const who = row.author?.name.trim() || owner;
      if (text || row.images?.length) blocks.push(`**${who}:**\n${text || "(attachment)"}`);
    } else if (row.kind === "assistant" && text) {
      blocks.push(`**${agent}:**\n${text}`);
    }
    for (const item of row.items ?? []) {
      const title = item.tool?.title.trim().replace(/\s+/gu, " ");
      if (title) blocks.push(`- Tool: ${title.length > 160 ? `${title.slice(0, 157)}…` : title}`);
    }
  }
  return blocks;
}

/**
 * The continuation: the intro, then the newest turns that fit within `limit` bytes, with the cut note where
 * older ones were left out. Undefined when the chat has nothing to carry yet.
 */
export function continueCapsule(
  rows: readonly AcpmuxRow[],
  source: ContinueSource,
  limit = CONTINUE_LIMIT_BYTES,
): string | undefined {
  const blocks = continueBlocks(rows, source.owner, source.agent);
  if (!blocks.length) return undefined;
  const heading = source.title?.trim() ? `${source.intro}\n\n# ${source.title.trim()}` : source.intro;
  const separator = "\n\n";
  let room = limit - bytes(heading) - bytes(separator) - bytes(source.cut) - bytes(separator);
  const kept: string[] = [];
  for (let index = blocks.length - 1; index >= 0; index--) {
    const size = bytes(blocks[index]!) + bytes(separator);
    if (size > room) break;
    room -= size;
    kept.unshift(blocks[index]!);
  }
  // The newest turn alone is over the bound: its tail, cut on a whole character.
  if (!kept.length) {
    const newest = encoder.encode(blocks.at(-1)!);
    const tail = newest.subarray(Math.max(0, newest.length - Math.max(0, room - bytes("…"))));
    // A cut inside a character decodes to U+FFFD at the start: drop it.
    kept.push(`…${new TextDecoder().decode(tail).replace(/^�+/u, "")}`);
  }
  const parts = [heading];
  if (kept.length < blocks.length) parts.push(source.cut);
  parts.push(...kept);
  return parts.join(separator);
}

/** Copies the continuation; false when the clipboard refused (the page then shows the text to copy by hand). */
export async function copyContinue(
  text: string,
  clipboard: Pick<Clipboard, "writeText"> | undefined = globalThis.navigator?.clipboard,
) {
  try {
    await clipboard?.writeText(text);
    return clipboard !== undefined;
  } catch {
    return false;
  }
}
