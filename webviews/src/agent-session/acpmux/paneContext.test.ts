import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "./model";
import { paneContext, workingURLs } from "./paneContext";

const row = (id: string, text: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind: "assistant",
  text,
  ...extra,
});

describe("what an agent is working on", () => {
  test("puts dev servers first, then pull requests, newest first within each, and nothing else", () => {
    const rows = [
      row("1", "Docs at https://example.com/a. Server on http://localhost:3000/"),
      row("2", "Opened https://github.com/manaflow-ai/cmux/pull/42, see https://example.com/b"),
      row("3", "Now on http://0.0.0.0:5173/app"),
    ];
    expect(workingURLs(rows)).toEqual([
      "http://localhost:5173/app",
      "http://localhost:3000/",
      "https://github.com/manaflow-ai/cmux/pull/42",
    ]);
    expect(workingURLs([row("1", "Read https://example.com/docs")])).toEqual([]);
  });

  test("finds an older dev server behind many newer links", () => {
    const links = Array.from({ length: 25 }, (_, index) => row(`d${index}`, `See https://example.com/doc/${index}`));
    expect(workingURLs([row("dev", "Server on http://localhost:3000/"), ...links], 20)).toEqual([
      "http://localhost:3000/",
    ]);
  });

  test("reads tool output and drops duplicates and trailing punctuation", () => {
    const rows = [
      row("1", "", {
        kind: "activity",
        items: [
          {
            kind: "tool",
            text: "Run",
            tool: { id: "t", title: "npm run dev", status: "completed", output: "ready at http://127.0.0.1:8080/!" },
          },
        ],
      }),
      row("2", "See http://127.0.0.1:8080/."),
    ];
    expect(workingURLs(rows)).toEqual(["http://127.0.0.1:8080/"]);
  });

  test("gives the selected session's cwd", () => {
    const snapshot = {
      rows: [row("1", "no links")],
      sessions: [
        { sessionId: "a", cwd: "/w/a" },
        { sessionId: "b", cwd: "/w/b" },
      ],
      sessionId: "b",
    };
    expect(paneContext(snapshot)).toEqual({ cwd: "/w/b", urls: [] });
    expect(paneContext({ ...snapshot, sessionId: undefined })).toEqual({ urls: [] });
  });
});
