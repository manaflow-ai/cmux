// The Feed page's pure presentation, ported from the Swift Feed (FeedDrafts, FeedChoiceValidation,
// FeedRelativeTime, ReportReply, FeedRowContent's meta line, FeedStrings.closed).
import { describe, expect, test } from "bun:test";
import type { Strings } from "../shared/i18n";
import { formatString } from "../shared/i18n";
import generated from "./generated/strings.json";
import { MockFeedProvider, rowOf, sampleFeed, type MockItem } from "./mockProvider";
import {
  choiceIssues,
  clearDrafts,
  closedStatus,
  EMPTY_DRAFTS,
  inboxLines,
  isOneTap,
  metaLine,
  moveSelection,
  normalizedChoice,
  parseRoute,
  relativeTime,
  reportReply,
  setOther,
  snoozeUntil,
  splitNeedsYou,
  toggleChoice,
} from "./model";
import type { FeedChoiceQuestion, ViewItem } from "./types";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings: Pick<Strings, "t" | "format"> = {
  t: (key) => en[key] ?? key,
  format: (key, ...args) => formatString(en[key] ?? en[`${key}#other`] ?? key, args),
};
const NOW = Date.parse("2026-11-06T12:00:00Z");
const view = (item: MockItem): ViewItem => ({ ...item, row: rowOf(item), pending: false });
const seed = () => sampleFeed(NOW);
const byId = (id: string) => view(seed().find((item) => item.id === id)!);

const single: FeedChoiceQuestion = {
  id: "q1",
  question: "Which?",
  options: [
    { id: "a", label: "A" },
    { id: "b", label: "B" },
  ],
};
const multi: FeedChoiceQuestion = { ...single, id: "q2", multi: true, allow_other: true };

describe("route", () => {
  test("each view has its own surface by default; the query and the host's attributes set it", () => {
    expect(parseRoute("#/inbox")).toMatchObject({ view: "inbox", surface: "page", style: "rows", limit: 3 });
    expect(parseRoute("#/list").surface).toBe("sidebar");
    expect(parseRoute("#/list?surface=panel").surface).toBe("sidebar");
    expect(parseRoute("#/list", { surface: "sidebar" }).surface).toBe("sidebar");
    expect(parseRoute("#/list?surface=page", { surface: "sidebar" }).surface).toBe("page");
    expect(parseRoute("#/needs-you?style=bar&limit=5")).toMatchObject({ view: "needs-you", style: "bar", limit: 5 });
    expect(parseRoute("#/needs-you", { style: "cards" }).style).toBe("cards");
    expect(parseRoute("#/elsewhere?style=nope&limit=-1")).toMatchObject({ view: "inbox", style: "rows", limit: 3 });
    expect(parseRoute("#/inbox?density=compact").density).toBe("compact");
  });
});

describe("drafts", () => {
  test("a single-select question keeps one option and drops Other", () => {
    let drafts = setOther(EMPTY_DRAFTS, "i", single, "typed");
    drafts = toggleChoice(drafts, "i", single, "a");
    expect(drafts.choices.i!.q1).toEqual({ selected: ["a"] });
    drafts = toggleChoice(drafts, "i", single, "b");
    expect(drafts.choices.i!.q1!.selected).toEqual(["b"]);
    drafts = toggleChoice(drafts, "i", single, "b");
    expect(drafts.choices.i!.q1!.selected).toEqual([]);
  });

  test("a multi-select question adds options; Other on a single one clears its pick", () => {
    let drafts = toggleChoice(EMPTY_DRAFTS, "i", multi, "a");
    drafts = toggleChoice(drafts, "i", multi, "b");
    expect(drafts.choices.i!.q2!.selected).toEqual(["a", "b"]);
    drafts = setOther(drafts, "i", multi, "c");
    expect(drafts.choices.i!.q2).toEqual({ selected: ["a", "b"], other: "c" });
    const one = setOther(toggleChoice(EMPTY_DRAFTS, "i", single, "a"), "i", single, "x");
    expect(one.choices.i!.q1).toEqual({ selected: [], other: "x" });
  });

  test("clearing an item drops every kind of draft and keeps the others", () => {
    const drafts = { choices: { i: {}, j: {} }, replies: { i: "x" }, scopes: { i: "session" as const } };
    expect(clearDrafts(drafts, "i")).toEqual({ choices: { j: {} }, replies: {}, scopes: {} });
    expect(clearDrafts(EMPTY_DRAFTS, "i")).toBe(EMPTY_DRAFTS);
  });
});

describe("choice validation", () => {
  test("every question needs an answer; one per single-select question; Other only where allowed", () => {
    expect(choiceIssues({}, [single])).toEqual([{ kind: "unanswered", question: "q1" }]);
    expect(choiceIssues({ q1: { selected: ["a", "b"] } }, [single])).toEqual([{ kind: "tooMany", question: "q1" }]);
    expect(choiceIssues({ q1: { selected: ["z"] } }, [single])).toContainEqual({
      kind: "unknownOption",
      question: "q1",
      option: "z",
    });
    expect(choiceIssues({ q1: { selected: [], other: "x" } }, [single])).toContainEqual({
      kind: "otherNotAllowed",
      question: "q1",
    });
    expect(choiceIssues({ nope: { selected: [] }, q1: { selected: ["a"] } }, [single])).toEqual([
      { kind: "unknownQuestion", question: "nope" },
    ]);
    expect(choiceIssues({ q2: { selected: [], other: "  " } }, [multi])).toEqual([
      { kind: "unanswered", question: "q2" },
    ]);
  });

  test("a sendable answer loses blank Other text; one with issues is not sendable", () => {
    expect(normalizedChoice({ q2: { selected: ["a"], other: "  " } }, [multi])).toEqual({ q2: { selected: ["a"] } });
    expect(normalizedChoice({ q2: { selected: [], other: " c " } }, [multi])).toEqual({
      q2: { selected: [], other: "c" },
    });
    expect(normalizedChoice({}, [single])).toBeUndefined();
  });

  test("one single-select question answers on the tap", () => {
    expect(isOneTap([single])).toBe(true);
    expect(isOneTap([multi])).toBe(false);
    expect(isOneTap([single, single])).toBe(false);
  });
});

describe("rows", () => {
  test("relative times are one unit, rounded down", () => {
    expect(relativeTime(NOW - 40_000, NOW, "en")).toBe("40s");
    expect(relativeTime(NOW - 190_000, NOW, "en")).toBe("3m");
    expect(relativeTime(NOW - 2 * 3_600_000 - 5, NOW, "en")).toBe("2h");
    expect(relativeTime(NOW - 30 * 3_600_000, NOW, "en")).toBe("1d");
    expect(relativeTime(NOW + 5_000, NOW, "en")).toBe("0s");
  });

  test("the meta line says who, where, the closed state, the repeat count and the thread size", () => {
    const answered = byId("fi_answered_push");
    expect(metaLine(answered, 1, strings)).toBe("Claude Code · api-server · Answered on iPhone");
    expect(metaLine({ ...byId("fi_build_retry") }, 3, strings)).toBe("ci-runner · ×2 · 3 items");
  });

  test("closed states read as the Swift Feed's", () => {
    expect(closedStatus(byId("fi_claude_rm_build"), strings)).toBeUndefined();
    expect(closedStatus(byId("fi_expired_npm"), strings)).toBe("Expired");
    expect(closedStatus(byId("fi_declined_install"), strings)).toBe("Declined");
    const elsewhere = { ...byId("fi_declined_install"), cancel: { reason: "answered_elsewhere" } };
    expect(closedStatus(elsewhere, strings)).toBe("Answered in the terminal");
    const noDevice = { ...byId("fi_answered_push"), answer: {} };
    expect(closedStatus(noDevice, strings)).toBe("Answered");
  });

  test("a row's detail is code for a command; a generic title gives way to its detail", () => {
    expect(byId("fi_claude_rm_build").row).toMatchObject({
      headline: "Run rm -rf build && npm run build?",
      // The title already says the command, so no detail line; it would be drawn as code.
      detail_is_code: true,
      icon: "terminal",
      urgent: true,
      who: "Claude Code",
      where: "api-server",
    });
    expect(byId("fi_codex_edit").row).toMatchObject({ detail: "Apply patch to 1 file", icon: "action.edit" });
    const generic = view({ ...seed()[0]!, title: "Claude Code" });
    expect(generic.row.headline).toBe("rm -rf build && npm run build");
    expect(generic.row.detail).toBeUndefined();
    expect(byId("fi_osc9").row.local).toBe(true);
    expect(byId("fi_claude_plan").row.urgent).toBe(false);
  });

  test("the Inbox draws each group's title and count, then a row per item or thread", () => {
    const provider = new MockFeedProvider(seed(), { now: () => NOW });
    const result = provider.view({ layout: "inbox", tz_offset_min: 0 });
    const lines = inboxLines(result.groups, "fi_build_retry", () => false, strings.t);
    const headers = lines.filter((line) => line.type === "header");
    expect(headers.map((h) => h.type === "header" && [h.title, h.count])).toEqual([
      ["Needs you", 11],
      ["Today", expect.any(Number)],
      ["Earlier", expect.any(Number)],
    ]);
    const ci = lines.find((line) => line.type === "row" && line.entry.item.id === "fi_build_done");
    expect(ci).toMatchObject({ threadCount: 2, selected: true });
    const plainLines = inboxLines(result.groups, undefined, () => false, strings.t);
    expect(moveSelection(plainLines, undefined, 1)).toBe(result.groups[0]!.entries[0]!.item.id);
    expect(moveSelection(plainLines, undefined, -1)).toBe(result.groups.at(-1)!.entries.at(-1)!.item.id);
    expect(moveSelection(lines, "fi_build_retry", 1)).not.toBe("fi_build_done");
    const last = result.groups.at(-1)!.entries.at(-1)!.item.id;
    expect(moveSelection(plainLines, last, 1)).toBe(last);
  });
});

describe("needs you, snooze and reports", () => {
  test("past the limit the rest are counted", () => {
    expect(splitNeedsYou([1, 2, 3, 4, 5], 3)).toEqual({ shown: [1, 2, 3], more: 2 });
    expect(splitNeedsYou([1], 3)).toEqual({ shown: [1], more: 0 });
    expect(splitNeedsYou([1, 2], 0)).toEqual({ shown: [1], more: 1 });
  });

  test("snooze for an hour or until tomorrow", () => {
    expect(snoozeUntil(NOW, "hour")).toBe(NOW + 3_600_000);
    expect(snoozeUntil(NOW, "tomorrow")).toBe(NOW + 86_400_000);
  });

  test("a reply sent again keeps its id; a changed one gets a new id", () => {
    let n = 0;
    const mint = () => `id-${++n}`;
    const first = reportReply("s", "hi", undefined, mint);
    expect(first.promptId).toBe("id-1");
    expect(reportReply("s", "hi", first, mint).promptId).toBe("id-1");
    expect(reportReply("s", "hi!", first, mint).promptId).toBe("id-2");
    expect(reportReply("t", "hi", first, mint).promptId).toBe("id-3");
  });
});
