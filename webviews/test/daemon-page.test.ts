// The chat benches' stand-in daemons page as acpmux does (bench/daemonPage.ts, hub/paging.rs
// `events_page`): by count and by `maxBytes`, so a god session with MB tool outputs opens on the
// page the pane would get. A stand-in that ignored `maxBytes` served the god session's switch a
// 1.2 MB page where acpmux sends 128 KiB. A page bounded by bytes also folds a command's cumulative output
// updates to its newest (store/superseded.rs), as acpmux does.
import { describe, expect, test } from "bun:test";
import { DEFAULT_PAGE_BYTES, MAX_PAGE_BYTES, newestPage, recordBytes } from "../bench/daemonPage";
import { godChat } from "../bench/godFixture";
import { toRecord } from "../bench/replayLogs";

const records = (sizes: number[]) => sizes.map((size, index) => ({ seq: index + 1, msg: { text: "x".repeat(size) } }));

describe("stand-in daemon paging", () => {
  test("the newest records by count, oldest first", () => {
    const { page, hasMore } = newestPage(records([1, 1, 1, 1, 1]), { limit: 3 });
    expect(page.map((event) => event.seq)).toEqual([3, 4, 5]);
    expect(hasMore).toBe(true);
  });

  test("before a seq", () => {
    const { page, hasMore } = newestPage(records([1, 1, 1, 1, 1]), { limit: 10, beforeSeq: 4 });
    expect(page.map((event) => event.seq)).toEqual([1, 2, 3]);
    expect(hasMore).toBe(false);
  });

  test("ends before its JSON passes maxBytes, and always holds one record", () => {
    const events = records([100, 100, 100, 5000]);
    const one = recordBytes(events[0]);
    const { page, hasMore } = newestPage(events, { maxBytes: recordBytes(events[3]) + 2 * one - 1 });
    expect(page.map((event) => event.seq)).toEqual([3, 4]);
    expect(hasMore).toBe(true);
    expect(newestPage(events, { maxBytes: 10 }).page.map((event) => event.seq)).toEqual([4]);
  });

  test("no maxBytes is acpmux's 1 MiB page, and an ask holds at most 4 MiB", () => {
    const events = records(Array.from({ length: 8 }, () => 600 * 1024));
    expect(newestPage(events).page).toHaveLength(Math.floor(DEFAULT_PAGE_BYTES / recordBytes(events[0])));
    expect(newestPage(events, { maxBytes: 64 << 20 }).page).toHaveLength(
      Math.floor(MAX_PAGE_BYTES / recordBytes(events[0])),
    );
  });

  test("a page bounded by bytes folds a call's cumulative output updates to its newest", () => {
    const output = (text: string) => [{ type: "content", content: { type: "text", text } }];
    const id = "call-1";
    const steps = [
      { mux: "user_message", msg: { text: "go" } },
      { update: { sessionUpdate: "tool_call", toolCallId: id, kind: "execute", title: "Run", status: "in_progress" } },
      ...[1, 2, 3, 4, 5].map((n) => ({
        update: {
          sessionUpdate: "tool_call_update",
          toolCallId: id,
          status: "in_progress",
          content: output("x".repeat(n * 100)),
        },
      })),
      {
        update: { sessionUpdate: "tool_call_update", toolCallId: id, status: "completed", rawOutput: { exit_code: 0 } },
      },
    ];
    const events = steps.map((step, index) => toRecord("s", index + 1, index, step as Parameters<typeof toRecord>[3]));
    const before = JSON.stringify(events);
    expect(newestPage(events, { maxBytes: 128 * 1024 }).page.map((event) => event.seq)).toEqual([1, 2, 7, 8]);
    // Read with no byte bound, every record goes out, and the log itself is never changed.
    expect(newestPage(events).page).toHaveLength(8);
    expect(JSON.stringify(events)).toBe(before);
  });

  test("the god session's open page is cut to the pane's 128 KiB ask", () => {
    const { events } = godChat("god-page");
    const { page, hasMore } = newestPage(events, { limit: 400, maxBytes: 128 * 1024 });
    const bytes = page.reduce((sum, event) => sum + recordBytes(event), 0);
    expect(hasMore).toBe(true);
    expect(bytes).toBeLessThanOrEqual(128 * 1024);
    // At most one record of a call carries its output.
    const withContent = page.filter((event) => {
      const update = (event.msg as { params?: { update?: { sessionUpdate?: string; content?: unknown } } }).params
        ?.update;
      return update?.sessionUpdate === "tool_call_update" && update.content !== undefined;
    });
    const ids = withContent.map(
      (event) => (event.msg as { params: { update: { toolCallId: string } } }).params.update.toolCallId,
    );
    expect(new Set(ids).size).toBe(ids.length);
  });
});
