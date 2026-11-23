// A transcript part that opens another chat on a click (`data-open-session`, menuParts.ts
// `openSessionAttributes`) is that chat's link chip (conversation/AgentTag.tsx), never a whole line:
// the chip is the one part that opens the chat and the one part that lights under the pointer (Leo,
// 2026-11-05: "subagents need to have their clickable bit be highlighted instead of the whole line
// click sending me to the subagent righ split"). A new opener marked `openSessionAttributes` that is
// not an AgentTag fails here; the few that are a chip or a button of their own already are listed
// with what they are. An opener without the attributes (a bare `onClick={() => open(id)}`) is not
// seen: give every opener the attributes, as the right-click menu needs them anyway (menuParts.ts).
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

const SRC = path.resolve(import.meta.dir, "../src");

/// Openers that are not an AgentTag but are only the clickable bit already, by file: how many, and why.
const NOT_A_LINE: Record<string, { count: number; why: string }> = {
  "agent-session/acpmux/conversation/SessionRef.tsx": { count: 1, why: "a session's name in a reply, an inline chip" },
  "agent-session/acpmux/started/StartedSessionCard.tsx": {
    count: 2,
    why: "an inline session chip, and a started chats list row (a list's row is the chat, as the running tray's)",
  },
  "agent-session/acpmux/planBuild/PlanBuildCard.tsx": { count: 1, why: "an Open button whose word is the action" },
};

function sources(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return sources(full);
    return entry.name.endsWith(".tsx") && !/\.(test|gallery)\.tsx$/.test(entry.name) ? [full] : [];
  });
}

test("every part that opens another chat is an AgentTag chip, not a whole line", () => {
  const offenders: string[] = [];
  const counts = new Map<string, number>();
  for (const file of sources(SRC)) {
    const text = readFileSync(file, "utf8");
    const rel = path.relative(SRC, file).split(path.sep).join("/");
    for (const match of text.matchAll(/openSessionAttributes\(/g)) {
      // The JSX element the call's attributes land on: the last tag opened before it.
      const tags = [...text.slice(0, match.index).matchAll(/<([A-Za-z][\w.]*)/g)];
      const tag = tags.at(-1)?.[1];
      if (tag === "AgentTag") continue;
      counts.set(rel, (counts.get(rel) ?? 0) + 1);
      if (!NOT_A_LINE[rel]) {
        const line = text.slice(0, match.index).split("\n").length;
        offenders.push(`${rel}:${line} opens a chat from <${tag}>: make its name an AgentTag with onClick`);
      }
    }
  }
  expect(offenders).toEqual([]);
  // The list only shrinks: a listed file that gains an opener, or loses one, says so.
  for (const [rel, { count }] of Object.entries(NOT_A_LINE))
    expect(`${rel}: ${counts.get(rel) ?? 0}`).toBe(`${rel}: ${count}`);
});
