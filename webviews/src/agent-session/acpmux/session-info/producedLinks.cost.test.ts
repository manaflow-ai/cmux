// Session Info's Outputs reads what the chat produced (producedLinks.ts) on every update that reaches
// the pane while a reply streams. Its cost per update must not grow with the chat's history (Leo,
// 2026-11-04: "It should just never, ever ... be acceptable for there to be some sort of linear time
// growth degradation"): a past call's command and output are parsed once, when its row first shows,
// never again for a later token.
//
// A chat of N past turns, each a reply and a `gh pr create` whose output counts its reads, then one
// update: the streaming reply grew. The update must read no past call, at N = 10 as at N = 100.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { producedLinks } from "./producedLinks";

const filler = (seed: string) => Array.from({ length: 200 }, (_, index) => `${seed} line ${index}`).join("\n");

function pastTurn(n: number, reads: { count: number }): AcpmuxRow[] {
  const output = `${filler(`push ${n}`)}\nhttps://github.com/o/r/pull/${n + 1}\n`;
  const tool = {
    id: `create-${n}`,
    kind: "execute",
    title: "gh pr create",
    status: "completed",
    command: `gh pr create --title "Change ${n}" --body-file /tmp/body${n}.md`,
    get output() {
      reads.count += 1;
      return output;
    },
  };
  return [
    { id: `reply-${n}`, version: 1, at: n, kind: "assistant", text: `Opened the PR for change ${n}.` },
    {
      id: `activity-${n}`,
      version: 1,
      at: n,
      kind: "activity",
      items: [{ kind: "tool", tool }],
    } as unknown as AcpmuxRow,
  ];
}

function update(turns: number) {
  const reads = { count: 0 };
  const history = Array.from({ length: turns }, (_, n) => pastTurn(n, reads)).flat();
  const streaming = (text: string): AcpmuxRow => ({
    id: "live",
    version: text.length,
    at: turns,
    kind: "assistant",
    text,
    streaming: true,
  });
  const before = producedLinks([...history, streaming("Merged #1 and")], "o/r");
  reads.count = 0;
  const started = performance.now();
  const after = producedLinks([...history, streaming("Merged #1 and opened")], "o/r");
  const ms = performance.now() - started;
  return { reads: reads.count, ms, before, after };
}

test("one streamed update reads no past call, however long the chat", () => {
  const ten = update(10);
  const hundred = update(100);
  console.log(
    `PRODUCED-COST ${JSON.stringify({ n10: { reads: ten.reads, ms: +ten.ms.toFixed(2) }, n100: { reads: hundred.reads, ms: +hundred.ms.toFixed(2) } })}`,
  );
  expect(hundred.after).toHaveLength(100);
  expect(hundred.after).toEqual(hundred.before);
  // The streaming reply's claim is not read until it settles.
  expect(hundred.after.some((link) => link.merged)).toBe(false);
  expect(ten.reads, "past call outputs read for one update, N = 10").toBe(0);
  expect(hundred.reads, "past call outputs read for one update, N = 100").toBe(0);
});
