// A fold's copies (turnFold.ts ghostOf) live only while their fold plays. A copy a fold left behind
// stayed in the thread at full ink: in a long chat the turn-end fold's copies of four folded progress
// messages drew over an earlier reply the reader scrolled up to, until the page reloaded (CMUX-896).
// The transcript now takes out, at its next commit, every copy no playing fold owns
// (`sweepFoldCopies`), and a settled turn-end fold never draws a copy again (`settleTurnEnd`).
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { ghostOf, placeCopy, sweepFoldCopies } from "./turnFold";
import { settleTurnEnd, type TurnEndFold } from "./turnEndFold";

function thread() {
  const { document } = new JSDOM("<!doctype html><body></body>").window;
  const host = document.createElement("div");
  host.className = "acpmux-thread";
  document.body.append(host);
  const row = (id: string, text: string) => {
    const node = document.createElement("div");
    node.className = "acpmux-row acpmux-assistant";
    node.dataset.rowId = id;
    node.textContent = text;
    host.append(node);
    return node;
  };
  return { document, host, row };
}

test("a fold copy no playing fold owns leaves the thread; owned copies and rows stay", () => {
  const { host, row } = thread();
  const answer = row("answer", "The file fold animation is back.");
  const folded = row("progress-1", "The base moved 1876 commits.");
  const left = ghostOf(folded);
  placeCopy(host, left, answer);
  folded.remove();
  const playing = ghostOf(answer);
  placeCopy(host, playing, answer);

  expect(sweepFoldCopies(host, (copy) => copy === playing)).toBe(1);
  expect(left.isConnected).toBe(false);
  expect(playing.isConnected).toBe(true);
  expect(answer.isConnected).toBe(true);
  // Nothing left to take: the next commit's sweep takes none.
  expect(sweepFoldCopies(host, (copy) => copy === playing)).toBe(0);
});

test("only copies a fold put in are swept: a copy a fold took out is forgotten, and swept again when put back", () => {
  const { host, row } = thread();
  // A clone a fold never put in the thread (another surface's) is not the sweep's.
  const card = row("card", "");
  card.append(ghostOf(row("inner", "inner")));
  expect(sweepFoldCopies(host, () => false)).toBe(0);
  expect(card.childElementCount).toBe(1);
  // A fold took its copy out: the next sweep forgets it. Put in again, it is swept again.
  const copy = ghostOf(row("progress-3", "The team runs the typecheck."));
  placeCopy(host, copy, null);
  copy.remove();
  expect(sweepFoldCopies(host, () => false)).toBe(0);
  placeCopy(host, copy, null);
  expect(sweepFoldCopies(host, () => false)).toBe(1);
  expect(sweepFoldCopies(null, () => false)).toBe(0);
});

test("a settled turn-end fold is done and its copies are gone", () => {
  const { host, row } = thread();
  const copy = ghostOf(row("progress-2", "Tests pass on the rebased branch."));
  placeCopy(host, copy, null);
  let ended = 0;
  const fold: TurnEndFold = { animations: new Set(), copies: new Set([copy]), ended: () => (ended += 1) };
  settleTurnEnd(host, fold);
  expect(fold.done).toBe(true);
  expect(copy.isConnected).toBe(false);
  expect(fold.copies.size).toBe(0);
  expect(ended).toBe(1);
  // What the transcript's sweep asks of it after: a settled fold owns no copy, so one put back is swept.
  placeCopy(host, copy, null);
  expect(sweepFoldCopies(host, (node) => fold.done !== true && fold.copies.has(node))).toBe(1);
});
