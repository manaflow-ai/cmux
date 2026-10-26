// `debug.agent_pane seed_rows` with `fixture: "shared"`: the real app's capture of a shared chat
// draws teammates' prompts and the live faces for the chat on screen.
import { afterEach, expect, test } from "bun:test";
import { createAcpmuxDebug } from "../debug";
import type { AcpmuxRow } from "../model";
import { acpmuxPerf } from "../perf";
import { shownPresence } from "./LivePresence";

afterEach(() => shownPresence.set(undefined, undefined));

test("the shared fixture seeds teammates' rows and shows who is here, for the chat on screen", async () => {
  let rows: AcpmuxRow[] = [];
  const debug = createAcpmuxDebug({
    // The pane commits the rows it is given; the seed waits for that commit.
    replaceRows: (next) => {
      rows = next;
      queueMicrotask(() => acpmuxPerf.commit(1, 0, [], performance.now()));
    },
    rowCount: () => rows.length,
    sessionId: () => "chat-a",
  });
  const seeded = await debug.seedRows(0, "shared");
  expect(seeded.rows).toBe(rows.length);
  expect(rows.filter((row) => row.author).map((row) => row.author!.name)).toEqual(["Ana Ruiz", "Sam Okafor"]);
  expect(rows.find((row) => row.answeredBy)?.answeredBy?.name).toBe("Sam Okafor");
  expect(shownPresence.get()?.sessionId).toBe("chat-a");
  expect(shownPresence.get()?.presence?.viewing.map((p) => p.name)).toEqual(["Ana Ruiz", "Sam Okafor", "Mei Lin"]);
  expect(shownPresence.get()?.presence?.typing.map((p) => p.name)).toEqual(["Ana Ruiz"]);
});
