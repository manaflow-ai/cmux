// l10n-allow-file: test fixtures.
import { describe, expect, it } from "bun:test";
import { conversation, ME, sampleConversations } from "./fixtures";
import { headerLayout, listMetrics } from "./layout";
import {
  conversationNumber,
  holdsOneConversation,
  listModel,
  listTime,
  neighbor,
  placePinned,
  unreadConversations,
  type ListOptions,
} from "./model";

const NOW = new Date(2026, 10, 6, 15, 30).getTime();
const words: ListOptions["words"] = {
  untitled: "Conversation",
  yesterday: "Yesterday",
  channel: "Channel",
  mentioned: "Mentions you",
  unread: (n) => `${n} unread`,
};
const options = (extra: Partial<ListOptions> = {}): ListOptions => ({
  me: ME.id,
  now: NOW,
  language: "en-US",
  words,
  ...extra,
});
const ids = (items: readonly { id: string }[]) => items.map((item) => item.id);

describe("Messages list model", () => {
  it("puts my pins first in my pin order, then the rest newest first", () => {
    const model = listModel(sampleConversations(3, NOW), options());
    expect(ids(model.pinned)).toEqual(["c-chief", "c-taylor", "c-morgan", "c-casey"]);
    expect(ids(model.rows)).toEqual(["c-design", "c-dm-0", "c-dm-1", "c-dm-2", "c-trip"]);
  });

  it("keeps equal pin positions newest first and breaks activity ties by id", () => {
    const list = new Map(
      [
        conversation({ id: "b", pinned: true, lastAt: NOW - 10 }, NOW),
        conversation({ id: "a", pinned: true, lastAt: NOW }, NOW),
        conversation({ id: "d", lastAt: NOW }, NOW),
        conversation({ id: "c", lastAt: NOW }, NOW),
      ].map((c) => [c.id, c]),
    );
    const model = listModel(list, options());
    expect(ids(model.pinned)).toEqual(["a", "b"]);
    expect(ids(model.rows)).toEqual(["c", "d"]);
  });

  it("filters to unread conversations as rows, pinned ones first, with no grid", () => {
    const model = listModel(sampleConversations(8, NOW), options({ unreadOnly: true }));
    expect(model.pinned).toEqual([]);
    // Taylor has unread messages, Casey is marked unread; design has 5; every seventh DM has one.
    expect(ids(model.rows)).toEqual(["c-taylor", "c-casey", "c-design", "c-dm-0", "c-dm-7"]);
    expect(model.rows.every((row) => row.unread)).toBe(true);
  });

  it("counts a Mark as Unread as one unread and reads it out", () => {
    const casey = listModel(sampleConversations(0, NOW), options()).pinned.find((item) => item.id === "c-casey")!;
    expect(casey.unread).toBe(true);
    expect(casey.unreadCount).toBe(1);
    expect(casey.label).toContain("1 unread");
  });

  it("leaves muted conversations out of the unread count outside the list", () => {
    const model = listModel(sampleConversations(12, NOW), options());
    const muted = model.rows.find((row) => row.muted && row.unread);
    const unread = unreadConversations(model);
    expect(unread).toContain("c-taylor");
    expect(unread).not.toContain("c-trip");
    if (muted) expect(unread).not.toContain(muted.id);
  });

  it("searches titles, previews and member names, folding case and accents", () => {
    const list = sampleConversations(0, NOW);
    list.set("c-zoe", conversation({ id: "c-zoe", title: "Zoë", lastText: "Café at noon?" }, NOW));
    expect(ids(listModel(list, options({ query: "zoe" })).rows)).toEqual(["c-zoe"]);
    expect(ids(listModel(list, options({ query: "CAFE" })).rows)).toEqual(["c-zoe"]);
    // A member's name (Avery is in the design group).
    expect(ids(listModel(list, options({ query: "avery" })).rows)).toEqual(["c-design"]);
    // A search lists pinned matches as rows, first.
    const both = listModel(list, options({ query: "Taylor" }));
    expect(both.pinned).toEqual([]);
    expect(ids(both.rows)[0]).toBe("c-taylor");
  });

  it("combines a search with the Unread filter", () => {
    const model = listModel(sampleConversations(0, NOW), options({ query: "design", unreadOnly: true }));
    expect(ids(model.rows)).toEqual(["c-design"]);
    expect(listModel(sampleConversations(0, NOW), options({ query: "trip", unreadOnly: true })).rows).toEqual([]);
  });

  it("names a conversation with no title by its members, and tags a channel", () => {
    const model = listModel(sampleConversations(0, NOW), options());
    expect(model.pinned.find((item) => item.id === "c-taylor")?.title).toBe("Taylor Brooks");
    const design = model.rows.find((item) => item.id === "c-design")!;
    expect(design.channel).toBe(true);
    expect(design.badge).toBe("Channel");
    expect(design.label.startsWith("design, Channel, 5 unread, Mentions you")).toBe(true);
  });

  it("writes Messages' list times", () => {
    expect(listTime(new Date(2026, 10, 6, 9, 5).getTime(), NOW, "en-US", "Yesterday")).toBe("9:05 AM");
    expect(listTime(new Date(2026, 10, 5, 23, 0).getTime(), NOW, "en-US", "Yesterday")).toBe("Yesterday");
    expect(listTime(new Date(2026, 10, 3, 12, 0).getTime(), NOW, "en-US", "Yesterday")).toBe("Tuesday");
    expect(listTime(new Date(2026, 9, 1, 12, 0).getTime(), NOW, "en-US", "Yesterday")).toBe("10/1/26");
    expect(listTime(0, NOW, "en-US", "Yesterday")).toBe("");
  });

  it("moves through the grid then the rows, stopping at the ends unless it wraps", () => {
    const model = listModel(sampleConversations(1, NOW), options());
    expect(neighbor(model, undefined, 1)).toBe("c-chief");
    expect(neighbor(model, "c-casey", 1)).toBe("c-design");
    expect(neighbor(model, "c-chief", -1)).toBeUndefined();
    expect(neighbor(model, "c-trip", 1)).toBeUndefined();
    expect(neighbor(model, "c-trip", 1, true)).toBe("c-chief");
    expect(neighbor(model, "gone", 1)).toBe("c-chief");
    expect(conversationNumber(model, 2)).toBe("c-taylor");
    expect(conversationNumber(model, 9)).toBe("c-trip");
  });

  it("places a dragged tile or a dropped row in the grid's order", () => {
    const shown = ["a", "b", "c", "d"];
    expect(placePinned(shown, "a", 2)).toEqual(["b", "c", "a", "d"]);
    expect(placePinned(shown, "d", 0)).toEqual(["d", "a", "b", "c"]);
    expect(placePinned(shown, "x", 1)).toEqual(["a", "x", "b", "c", "d"]);
    expect(placePinned(shown, "b", 99)).toEqual(["a", "c", "d", "b"]);
  });

  it("folds only a list of one conversation with nothing under it", () => {
    const one = listModel(new Map([["only", conversation({ id: "only" }, NOW)]]), options());
    expect(holdsOneConversation(one, {})).toBe(true);
    expect(holdsOneConversation(one, { requests: 1 })).toBe(false);
    expect(holdsOneConversation(listModel(sampleConversations(0, NOW), options()), {})).toBe(false);
  });

  it("builds 10,000 rows in a blink", () => {
    const list = sampleConversations(10_000, NOW);
    const start = performance.now();
    const model = listModel(list, options());
    expect(model.rows.length).toBe(10_002);
    expect(performance.now() - start).toBeLessThan(2_000);
  });
});

describe("Messages list layout", () => {
  it("lays the grid out in 3, 2 or 1 columns by width", () => {
    expect(listMetrics(320).columns).toBe(3);
    expect(listMetrics(240).columns).toBe(2);
    expect(listMetrics(120).compact).toBe(true);
    expect(listMetrics(120).columns).toBe(1);
    const wide = listMetrics(320);
    expect(wide.pinAvatar).toBe(72);
    expect(wide.tileIndexAt(wide.tileRect(4).x + 5, wide.tileRect(4).y + 5, 9)).toBe(4);
    expect(wide.tileIndexAt(5, 5000, 3)).toBe(3);
  });

  it("puts the search under the traffic lights and the filter on their line", () => {
    const free = headerLayout(320, false, null, false);
    expect(free.search.y).toBe(11);
    expect(free.listTop).toBe(52);
    const lights = headerLayout(320, false, { x: 12, y: 14, width: 54, height: 16 }, false);
    expect(lights.filter.y).toBeLessThan(lights.search.y);
    expect(lights.search.width).toBe(300);
    expect(lights.listTop).toBeGreaterThan(52);
    const chip = headerLayout(320, false, null, true);
    expect(chip.filterChip.height).toBe(24);
    expect(chip.listTop).toBe(52 + 24 + 6);
    const compact = headerLayout(120, false, null, false);
    expect(compact.searchIcon.width).toBe(30);
    expect(headerLayout(120, true, null, false).buttonsCovered).toBe(true);
  });
});
