// Session Info reads what it lists of the rows on every update that reaches the pane while a reply
// streams (useSessionInfo.tsx `useSessionInfoLists`): its links, produced links, output files,
// gallery, documents, subagents and tool calls. Each list's cost per update must not grow with the
// chat's history. A pass that keeps each row's findings but still walks every row (a WeakMap lookup and
// a read of its kind or text per row, then a dedupe of every finding) costs a 100,000-row chat 100,000
// steps per list on each streamed token.
//
// A chat of N past turns (a prompt, a reply with a link and a file it points at, a call that opened a
// pull request), then one update: the streaming reply grew, and the client says the rows before it are
// kept (direct.ts `OrderedRows` → noteKeptPrefix). The update must read no past row, at N = 10 as at
// N = 1,000, and give each list back unchanged.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { noteKeptPrefix } from "../conversation/prefixFlatMap";
import { latestWrittenArtifacts } from "../conversation/writtenArtifactsModel";
import { chatGallery } from "../summary/chatGallery";
import { subagentsIn } from "../subagents/subagentRows";
import { chatOutputs } from "./chatOutputs";
import { outputArtifacts, outputLinks } from "./outputsSectionModel";
import { producedLinks } from "./producedLinks";
import { toolCallIds } from "./sessionInfoModel";

/// `row`, counting each read of its fields while `reads.on`.
function counted(row: AcpmuxRow, reads: { on: boolean; count: number }): AcpmuxRow {
  return new Proxy(row, {
    get(target, key, receiver) {
      if (reads.on) reads.count += 1;
      return Reflect.get(target, key, receiver);
    },
  });
}

function pastTurn(n: number): AcpmuxRow[] {
  return [
    { id: `user-${n}`, version: 1, at: n, kind: "user", text: `Ship change ${n}` },
    {
      id: `reply-${n}`,
      version: 1,
      at: n,
      kind: "assistant",
      text: `Opened it: see https://example.com/notes/${n} and \`/repo/out/report${n}.pdf\`.`,
    },
    {
      id: `activity-${n}`,
      version: 1,
      at: n,
      kind: "activity",
      items: [
        {
          kind: "tool",
          tool: {
            id: `create-${n}`,
            kind: "execute",
            title: "gh pr create",
            status: "completed",
            command: `gh pr create --title "Change ${n}"`,
            output: `https://github.com/o/r/pull/${n + 1}\n`,
          },
        },
      ],
    } as unknown as AcpmuxRow,
  ];
}

const lists = (rows: readonly AcpmuxRow[]) => ({
  links: outputLinks(rows),
  produced: producedLinks(rows, "o/r"),
  outputFiles: chatOutputs(rows, "/repo"),
  gallery: chatGallery(rows),
  documents: outputArtifacts(rows),
  written: latestWrittenArtifacts(rows),
  agents: subagentsIn(rows),
  toolCalls: toolCallIds(rows),
});

function update(turns: number) {
  const reads = { on: false, count: 0 };
  const history = Array.from({ length: turns }, (_, n) => pastTurn(n))
    .flat()
    .map((row) => counted(row, reads));
  const streaming = (text: string): AcpmuxRow => ({
    id: "live",
    version: text.length,
    at: turns,
    kind: "assistant",
    text,
    streaming: true,
  });
  const first = [...history, streaming("Merged #1 and")];
  const before = lists(first);
  const next = [...history, streaming("Merged #1 and opened")];
  noteKeptPrefix(next, first, history.length);
  reads.on = true;
  const after = lists(next);
  reads.on = false;
  return { reads: reads.count, before, after };
}

test("one streamed update reads no past row for Session Info's lists, however long the chat", () => {
  const ten = update(10);
  const thousand = update(1000);
  console.log(`SESSION-INFO-LISTS-COST ${JSON.stringify({ n10: ten.reads, n1000: thousand.reads })}`);
  expect(thousand.before.links).toHaveLength(1000);
  expect(thousand.before.produced).toHaveLength(1000);
  expect(thousand.before.outputFiles).toHaveLength(1000);
  expect(thousand.before.toolCalls.size).toBe(1000);
  expect(thousand.after).toEqual(thousand.before);
  expect(ten.reads, "past row reads for one update, N = 10").toBe(0);
  expect(thousand.reads, "past row reads for one update, N = 1,000").toBe(0);
  // What did not change is the same list, so nothing downstream compares it again.
  for (const key of ["links", "produced", "outputFiles", "gallery", "written", "toolCalls"] as const)
    expect(thousand.after[key], key).toBe(thousand.before[key]);
});
