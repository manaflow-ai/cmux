// A reply with two web links and a file path, for `debug.agent_pane seed_rows` with
// `fixture: "links"`: scripts/cmux-next/open-beside-e2e.py clicks them (open beside, ChatBeside).
// The links point at a loopback port the script serves; the path is a file it writes.
import type { AcpmuxRow } from "./model";

export const linksTurnPort = 47811;

/// The prompt and the reply with the links, starting at `at`.
export function linksTurnRows(at: number): AcpmuxRow[] {
  const base = `http://127.0.0.1:${linksTurnPort}`;
  return [
    { id: "links-user", version: 1, at, kind: "user", text: "Where are the PRs?" },
    {
      id: "links-reply",
      version: 1,
      at: at + 6_000,
      kind: "assistant",
      text: `Opened [PR one](${base}/pr/1) and [PR two](${base}/pr/2). The notes are in \`/tmp/cmux-open-beside/notes.md\`.`,
    },
  ] as AcpmuxRow[];
}
