import { describe, expect, test } from "bun:test";
import { validateEntries } from "../gallery/format";
import needsYouEntry from "./ProjectCapsNeedsYou.gallery";
import showMoreEntry from "./ProjectCapsDesigns.gallery";
import stickyEntry from "./ProjectCapsSticky.gallery";
import { capProjects } from "./projectCapsFixtures";
import { layoutProject, moreLabel, needsYou, PAGE_SIZE, RECENT_CAP, type CapChat } from "./projectCapsModel";

const chat = (index: number, extra: Partial<CapChat> = {}): CapChat => ({
  id: `c${index}`,
  title: `Chat ${index}`,
  harness: "claude",
  age: "1h",
  state: "idle",
  ...extra,
});

describe("project caps", () => {
  test("a project shows its 5 most recent chats, then pages of 20", () => {
    const layout = layoutProject(Array.from({ length: 50 }, (_, index) => chat(index)));
    expect(layout.rows.filter((row) => row.page === 0).map((row) => row.chat.id)).toEqual([
      "c0",
      "c1",
      "c2",
      "c3",
      "c4",
    ]);
    expect(layout.pageCounts).toEqual([PAGE_SIZE, PAGE_SIZE, 50 - RECENT_CAP - 2 * PAGE_SIZE]);
    expect(moreLabel(layout, 0)).toEqual({ kind: "more", count: 45 });
    expect(moreLabel(layout, 2)).toEqual({ kind: "more", count: 5 });
    expect(moreLabel(layout, 3)).toEqual({ kind: "less" });
  });

  test("a project under the cap has no Show more row", () => {
    expect(moreLabel(layoutProject([chat(0), chat(1)]), 0)).toBeNull();
  });

  test("pinned, then yellow, then blue float to the top; running keeps its place and always shows", () => {
    const chats = [
      chat(0),
      chat(1),
      chat(2, { state: "unread" }),
      chat(3),
      chat(4),
      chat(5),
      chat(6),
      chat(7, { state: "running" }),
      chat(8, { state: "waiting" }),
      chat(9, { pinned: true }),
    ];
    const rows = layoutProject(chats).rows;
    expect(rows.map((row) => row.chat.id)).toEqual(["c9", "c8", "c2", "c0", "c1", "c3", "c4", "c5", "c6", "c7"]);
    const shown = rows.filter((row) => row.page === 0).map((row) => row.chat.id);
    expect(shown).toEqual(["c9", "c8", "c2", "c0", "c1", "c7"]);
  });

  test("Needs you lists yellow before blue, at most 3", () => {
    const { shown, more } = needsYou(capProjects);
    expect(shown.map((chat) => chat.state)).toEqual(["waiting", "waiting", "unread"]);
    expect(more).toBe(2);
  });

  test("the gallery entries are valid and each offers more than two variants", () => {
    const entries = [showMoreEntry, stickyEntry, needsYouEntry];
    expect(validateEntries(entries)).toEqual([]);
    for (const entry of entries) expect(Object.keys(entry.variants).length).toBeGreaterThan(2);
  });
});
