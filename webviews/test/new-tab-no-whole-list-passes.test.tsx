// cmux-web-test-timeout: 240
// A New Tab page does no pass over the whole chat list on a key or on one chat's change (Leo: "Root-fix
// anything slow ... constant cost at scale"; hq docs/investigations/2026-11-18-boneheaded-designs.md,
// row 13, per-keypress whole-list passes). The page renders over a counting chat list
// (test/support/newTabScale.tsx): a pass over every chat reads SIZE elements, so the reads per move
// must be the same small number at 200 and at 2,000 chats. Before the fix, Minimal read 3 per chat
// on each chat's change (its recent project, the field's folders, the location strip's machines) and
// Classic 2 per chat on every key and every change (its recent project, its recent rows).
// The times: bench/new-tab-scale.bench.tsx.
import { expect, setDefaultTimeout, test } from "bun:test";
import { mountNewTab, type Look, type UpdateKind } from "./support/newTabScale";

setDefaultTimeout(120_000);

/// Element reads of the chat list per key and per change of each kind, after a warm-up of each.
async function readsPerMove(look: Look, size: number) {
  // "chat" matches the chats' titles, so the classic page lists its recent rows while typing.
  const page = await mountNewTab(size, { look, count: true, seed: "chat" });
  try {
    await page.key(" ");
    await page.update("status");
    await page.update("activity");
    page.reset();
    for (const letter of "abo") await page.key(letter);
    const key = page.reads() / 3;
    const updates: Record<UpdateKind, number> = { status: 0, activity: 0 };
    for (const kind of ["status", "activity"] as const) {
      page.reset();
      for (let round = 0; round < 4; round += 1) await page.update(kind);
      updates[kind] = page.reads() / 4;
    }
    return {
      key,
      ...updates,
      rows: document.querySelectorAll(".nt-row, .acpmux-newtab-row, [role=option]").length,
    };
  } finally {
    await page.close();
  }
}

test.each(["minimal", "classic"] as const)(
  "the %s New Tab page reads no whole chat list per key or change",
  async (look) => {
    const small = await readsPerMove(look, 200);
    const large = await readsPerMove(look, 2000);
    // The rows drew: the moves were measured on a page that lists what was typed.
    expect(large.rows).toBeGreaterThan(0);
    // A constant: a handful of the changed chat's own reads, never one per listed chat.
    for (const move of ["key", "status", "activity"] as const) {
      expect({ move, reads: large[move] }).toEqual({
        move,
        reads: small[move],
      });
      expect(large[move]).toBeLessThan(16);
    }
  },
);
