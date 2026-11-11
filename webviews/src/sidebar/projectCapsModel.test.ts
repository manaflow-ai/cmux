import { describe, expect, test } from "bun:test";
import { validateEntries } from "../gallery/format";
import needsYouEntry from "./ProjectCapsNeedsYou.gallery";
import showMoreEntry from "./ProjectCapsDesigns.gallery";
import stickyEntry from "./ProjectCapsSticky.gallery";
import { capProjects } from "./projectCapsFixtures";
import { isActive, layoutProject, moreLabel, needsYou, PAGE_SIZE, RECENT_CAP, type CapChat } from "./projectCapsModel";

const chat = (index: number, extra: Partial<CapChat> = {}): CapChat => ({
  id: `c${index}`,
  title: `Chat ${index}`,
  harness: "claude",
  age: "1h",
  state: "idle",
  ...extra,
});

describe("project caps", () => {
  test("a project shows its first 5 quiet chats, then pages of 20", () => {
    const layout = layoutProject(Array.from({ length: 50 }, (_, index) => chat(index)));
    expect(layout.rows.filter((row) => row.page === 0).map((row) => row.chat.id)).toEqual([
      "c0",
      "c1",
      "c2",
      "c3",
      "c4",
    ]);
    expect(layout.pageCounts).toEqual([PAGE_SIZE, PAGE_SIZE, 50 - RECENT_CAP - 2 * PAGE_SIZE]);
    expect(moreLabel(layout, 0)).toEqual({ kind: "more", count: 20 });
    expect(moreLabel(layout, 1)).toEqual({ kind: "more", count: 20 });
    expect(moreLabel(layout, 2)).toEqual({ kind: "more", count: 5 });
    expect(moreLabel(layout, 3)).toEqual({ kind: "less" });
  });

  test("a project under the cap has no Show more row", () => {
    expect(moreLabel(layoutProject([chat(0), chat(1)]), 0)).toBeNull();
  });

  test("one row over the cap shows whole", () => {
    const six = layoutProject(Array.from({ length: RECENT_CAP + 1 }, (_, index) => chat(index)));
    expect(six.pages).toBe(0);
    expect(six.rows.every((row) => row.page === 0)).toBe(true);
    expect(moreLabel(six, 0)).toBeNull();
    // 26 quiet: the first press reveals the last 21, so no lone row is left behind a Show more.
    const layout = layoutProject(Array.from({ length: RECENT_CAP + PAGE_SIZE + 1 }, (_, index) => chat(index)));
    expect(layout.pageCounts).toEqual([PAGE_SIZE + 1]);
    expect(moreLabel(layout, 0)).toEqual({ kind: "more", count: 20 });
    expect(moreLabel(layout, 1)).toEqual({ kind: "less" });
  });

  test("active rows never use up the cap", () => {
    const chats = [
      chat(0, { selected: true }),
      chat(1, { state: "running" }),
      chat(2, { state: "running" }),
      ...Array.from({ length: 10 }, (_, index) => chat(3 + index)),
    ];
    const shown = layoutProject(chats)
      .rows.filter((row) => row.page === 0)
      .map((row) => row.chat.id);
    expect(shown).toEqual(["c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7"]);
    expect(isActive(chats[0]!)).toBe(true);
  });

  test("pinned, then yellow, then blue float to the top; running and selected keep their place", () => {
    const chats = [
      chat(0),
      chat(1, { selected: true }),
      chat(2, { state: "unread" }),
      chat(3),
      chat(4),
      chat(5),
      chat(6),
      chat(7, { state: "running" }),
      chat(8, { state: "waiting" }),
      chat(9, { pinned: true }),
      chat(10),
      chat(11),
    ];
    const rows = layoutProject(chats).rows;
    expect(rows.map((row) => row.chat.id)).toEqual([
      "c9",
      "c8",
      "c2",
      "c0",
      "c1",
      "c3",
      "c4",
      "c5",
      "c6",
      "c7",
      "c10",
      "c11",
    ]);
    const shown = rows.filter((row) => row.page === 0).map((row) => row.chat.id);
    expect(shown).toEqual(["c9", "c8", "c2", "c0", "c1", "c3", "c4", "c5", "c6", "c7"]);
  });

  test("Needs you lists yellow before blue, at most 3, and keeps the rest for N more", () => {
    const { shown, rest, more } = needsYou(capProjects);
    expect(shown.map((chat) => chat.state)).toEqual(["waiting", "waiting", "unread"]);
    expect(rest.map((chat) => chat.state)).toEqual(["unread", "unread"]);
    expect(more).toBe(2);
  });

  test("the gallery entries are valid and each offers more than two variants", () => {
    const entries = [showMoreEntry, stickyEntry, needsYouEntry];
    expect(validateEntries(entries)).toEqual([]);
    for (const entry of entries) expect(Object.keys(entry.variants).length).toBeGreaterThan(2);
  });
});
