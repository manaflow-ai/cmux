// l10n-allow-file: test fixture recap text, not shipped UI.
// One "While you were away" card per chat (conversation/oneRecap.ts): a chat logged before acpmux
// kept one recap per chat holds a recap per return; only the newest shows, and dismissing it never
// brings an older one back.
import { expect, test } from "bun:test";
import { oneRecap } from "../src/agent-session/acpmux/conversation/oneRecap";
import { SINCE_DIVIDER, type AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000e9";
const recap = (seq: number, text = `The batch is merged (#34338). Recap ${seq}.`): AcpmuxRow => ({
  id: `recap-${seq}`,
  version: 1,
  at: seq * 1000,
  kind: "recap",
  recap: { key: `${CHAT}:${seq}`, text },
});
const reply = (seq: number): AcpmuxRow => ({
  id: `msg-${seq}`,
  version: 1,
  at: seq * 1000,
  kind: "assistant",
  text: "ok",
});
const none = () => [] as string[];
const recapIds = (rows: AcpmuxRow[]) => rows.filter((row) => row.kind === "recap").map((row) => row.id);

test("a legacy stack of eight recaps shows only the newest", () => {
  const rows = [1, 2, 3, 4, 5, 6, 7, 8].flatMap((n) => [reply(n * 10), recap(n * 10 + 1)]);
  const shown = oneRecap(rows, none);
  expect(recapIds(shown)).toEqual(["recap-81"]);
  expect(shown.filter((row) => row.kind === "assistant")).toHaveLength(8);
});

test("one recap and no dismissal: the same rows", () => {
  const rows = [reply(1), recap(2)];
  expect(oneRecap(rows, none)).toBe(rows);
  const plain = [reply(1), reply(2)];
  expect(oneRecap(plain, none)).toBe(plain);
});

test("dismissing the newest never brings an older one back", () => {
  const rows = [recap(11), reply(12), recap(21), reply(22), recap(31)];
  expect(recapIds(oneRecap(rows, () => [`${CHAT}:31`]))).toEqual([]);
  // An older recap dismissed: the newest still shows.
  expect(recapIds(oneRecap(rows, () => [`${CHAT}:11`]))).toEqual(["recap-31"]);
  // Another chat's dismissal does not count here.
  expect(recapIds(oneRecap(rows, () => ["another-chat:99"]))).toEqual(["recap-31"]);
});

test("a recap on New since you looked counts as one, and the divider stays without an older one", () => {
  const since = (seq: number, recapSeq: number): AcpmuxRow => ({
    id: SINCE_DIVIDER,
    version: 3,
    at: seq * 1000,
    kind: SINCE_DIVIDER,
    since: { key: `${CHAT}:${seq}`, seq, turns: 2, recap: { key: `${CHAT}:${recapSeq}`, text: "Merged." } },
  });
  // The divider's recap is the newest: the standalone ones go.
  const newest = oneRecap([recap(5), reply(6), since(40, 41)], none);
  expect(recapIds(newest)).toEqual([]);
  expect(newest.find((row) => row.id === SINCE_DIVIDER)?.since?.recap?.key).toBe(`${CHAT}:41`);
  // A newer standalone recap: the divider stays, without its recap.
  const older = oneRecap([since(40, 41), reply(42), recap(51)], none);
  expect(recapIds(older)).toEqual(["recap-51"]);
  const divider = older.find((row) => row.id === SINCE_DIVIDER);
  expect(divider?.since?.recap).toBeUndefined();
  expect(divider?.version).toBe(4);
});
