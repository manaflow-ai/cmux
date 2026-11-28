// l10n-allow-file: the rehearsal's sample chat, not shipped UI.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "./direct";
import type { AcpmuxRow } from "./model";
import { rehearsalEvents } from "./spareRehearsal";

test("the spare's sample chat folds into prompts, replies and tool calls through the real reducer", () => {
  const events = rehearsalEvents();
  let rows: readonly AcpmuxRow[] = [];
  const client = AcpmuxDirectClient.replay("rehearsal:spare", events, (snapshot) => {
    rows = snapshot.rows;
  });
  client.seekReplay(events.at(-1)!.seq);
  client.close();
  const kinds = new Set(
    rows.map((row) => (row as { kind?: string; type?: string }).kind ?? (row as { type?: string }).type),
  );
  expect(rows.length).toBeGreaterThan(9);
  expect(kinds.size).toBeGreaterThan(2);
  // The benches wait for "Answer"; the sample never says it.
  expect(JSON.stringify(rows)).not.toContain("Answer");
});

test("a hidden page still folds the sample (a parked spare reports hidden once it painted)", () => {
  const had = Object.getOwnPropertyDescriptor(globalThis, "document");
  Object.defineProperty(globalThis, "document", {
    configurable: true,
    value: { visibilityState: "hidden", addEventListener() {}, removeEventListener() {} },
  });
  try {
    const events = rehearsalEvents();
    let rows: readonly AcpmuxRow[] = [];
    const client = AcpmuxDirectClient.replay("rehearsal:spare", events, (snapshot) => {
      rows = snapshot.rows;
    });
    client.seekReplay(events.at(-1)!.seq);
    client.close();
    expect(rows.length).toBeGreaterThan(9);
  } finally {
    if (had) Object.defineProperty(globalThis, "document", had);
    else delete (globalThis as { document?: unknown }).document;
  }
});
