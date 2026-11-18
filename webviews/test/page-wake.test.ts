// l10n-allow-file: test fixture commands and file names, not shipped UI.
//
// What a chat page held that acpmux does not comes back on two paths: the handshake of a page built
// for the chat, and the adopt event of a prewarmed page that takes the chat (decision 2026-11-16: a
// hidden chat selected again takes the prewarmed page, where it loaded cold before). Both use the
// same two functions (pageWake.ts `readWake`, `applyWake`). These hold them:
//
//   - each part of the state goes to its place: the subagents' prompts, the composer, the chat's
//     folds, and the released page's place to the host;
//   - with no composer mounted (a prewarmed page shows its New Tab screen when the event comes), the
//     composer's part waits for the mount;
//   - another chat's folds and an unknown place go nowhere.
//
// No test here renders the page through an adopt event.
import { expect, test } from "bun:test";
import type { ComposerWake } from "../src/agent-session/acpmux/Composer";
import { applyWake, readWake, type WakeTargets } from "../src/agent-session/acpmux/pageWake";

const chip = { id: "a1", kind: "image" as const, name: "shot.png", mimeType: "image/png", size: 4, data: "iVBO" };

/// The page's places for a woken state, with what each got. `mounted`: the chat's composer is there.
function page(mounted: boolean) {
  const got = {
    drafts: [] as unknown[],
    composer: [] as ComposerWake[],
    held: [] as ComposerWake[],
    folds: [] as { session: string; expanded: string[] }[],
    places: [] as { session: string; anchor: unknown }[],
  };
  const to: WakeTargets = {
    subagentDrafts: (drafts) => got.drafts.push(drafts),
    composer: () => (mounted ? { wake: (state) => got.composer.push(state) } : null),
    holdForComposer: (state) => got.held.push(state),
    folds: (session, folds) => got.folds.push({ session, expanded: [...folds.expanded] }),
    place: (session, anchor) => got.places.push({ session, anchor }),
  };
  return { got, to };
}

const held = {
  attachments: [chip],
  shell: true,
  shellText: "git status",
  scrollAnchor: { rowId: "row-12", offset: 40 },
  subagentDrafts: { d1: { text: "next step", at: 1 } },
  folds: { session: "s-1", expanded: ["tool-3"] },
};

test("a woken state goes to the mounted composer, the folds, the subagent drafts and the host's place", () => {
  const wake = readWake(held);
  if (!wake) throw new Error("the state was not read");
  const { got, to } = page(true);
  applyWake(wake, "s-1", to);
  expect(got.drafts).toEqual([held.subagentDrafts]);
  expect(got.composer).toEqual([{ attachments: [chip], shell: true, shellText: "git status" }]);
  expect(got.held).toEqual([]);
  expect(got.folds).toEqual([{ session: "s-1", expanded: ["tool-3"] }]);
  expect(got.places).toEqual([{ session: "s-1", anchor: { rowId: "row-12", offset: 40 } }]);
});

test("with no composer mounted the composer's part waits for the mount", () => {
  const wake = readWake(held);
  if (!wake) throw new Error("the state was not read");
  const { got, to } = page(false);
  applyWake(wake, "s-1", to);
  expect(got.composer).toEqual([]);
  expect(got.held).toEqual([{ attachments: [chip], shell: true, shellText: "git status" }]);
  // The rest does not wait for a composer.
  expect(got.drafts.length).toBe(1);
  expect(got.folds.length).toBe(1);
  expect(got.places.length).toBe(1);
});

test("a page at its latest message tells the host that no place is kept, and an unknown place tells it nothing", () => {
  const latest = readWake({ atLatest: true });
  const unknown = readWake({ shell: true, shellText: "ls" });
  if (!latest || !unknown) throw new Error("the state was not read");
  const first = page(true);
  applyWake(latest, "s-1", first.to);
  expect(first.got.places).toEqual([{ session: "s-1", anchor: null }]);
  const second = page(true);
  applyWake(unknown, "s-1", second.to);
  expect(second.got.places).toEqual([]);
  expect(second.got.composer).toEqual([{ attachments: undefined, shell: true, shellText: "ls" }]);
});

test("another chat's folds stay closed, and a page with no chat keeps only the composer and the drafts", () => {
  const wake = readWake(held);
  if (!wake) throw new Error("the state was not read");
  const other = page(true);
  applyWake(wake, "s-2", other.to);
  expect(other.got.folds).toEqual([]);
  expect(other.got.places).toEqual([{ session: "s-2", anchor: { rowId: "row-12", offset: 40 } }]);
  const none = page(true);
  applyWake(wake, undefined, none.to);
  expect(none.got.composer.length).toBe(1);
  expect(none.got.drafts.length).toBe(1);
  expect(none.got.folds).toEqual([]);
  expect(none.got.places).toEqual([]);
});

test("what is no state reads as none", () => {
  for (const value of [undefined, null, "held", 7, false]) expect(readWake(value)).toBeUndefined();
});
