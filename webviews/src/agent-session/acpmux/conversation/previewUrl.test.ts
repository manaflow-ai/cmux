import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { latestLocalUrl, turnPreviewUrl } from "./previewUrl";
import { PREVIEW, turnView } from "./turns";

const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind,
  ...extra,
});
const shell = (id: string, command: string, output: string) =>
  row(id, "activity", 2, {
    items: [
      {
        kind: "tool",
        text: command,
        tool: { id, title: command, kind: "execute", status: "completed", command, output },
      },
    ],
  });

describe("a turn's local web page", () => {
  test("reads a loopback page from prose and server output, the latest one winning", () => {
    expect(latestLocalUrl(["Open http://localhost:5173/."])).toBe("http://localhost:5173/");
    expect(latestLocalUrl(["  ➜  Local:   http://127.0.0.1:3000/admin?tab=1"])).toBe(
      "http://127.0.0.1:3000/admin?tab=1",
    );
    expect(latestLocalUrl(["Listening on http://0.0.0.0:8080"])).toBe("http://localhost:8080/");
    expect(latestLocalUrl(["(see `http://localhost:4000/docs`)"])).toBe("http://localhost:4000/docs");
    expect(latestLocalUrl(["first http://localhost:3000", "then http://localhost:5173"])).toBe(
      "http://localhost:5173/",
    );
  });

  test("ignores pages a frame in the pane may not load", () => {
    expect(
      latestLocalUrl([
        "https://example.com/",
        "http://192.168.1.4:3000/",
        "http://localhost.evil.com/",
        "http://[::1]:3000/",
        "ws://localhost:3000/",
        "http://localhost:99999/",
      ]),
    ).toBeUndefined();
    expect(latestLocalUrl([undefined, ""])).toBeUndefined();
  });

  test("takes the prompt, the answers and the tool calls", () => {
    const user = row("u", "user", 0, { text: "why is http://localhost:3000 blank?" });
    expect(turnPreviewUrl(user, [])).toBe("http://localhost:3000/");
    expect(
      turnPreviewUrl(user, [
        shell("t", "bun run dev", "  Local: http://localhost:5173/"),
        row("a", "assistant", 3, { text: "Fixed." }),
      ]),
    ).toBe("http://localhost:5173/");
  });

  test("an ended turn shows its page as a card before the footer", () => {
    const rows = [
      row("u", "user", 0, { text: "start the dev server" }),
      shell("t", "bun run dev", "Local: http://localhost:5173/"),
      row("a", "assistant", 3, { text: "It runs at http://localhost:5173/." }),
      row("s", "turnSummary", 4, { durationMs: 4, toolCount: 1, status: "completed" }),
    ];
    const view = turnView(rows, new Set(), { now: 10 });
    const at = view.findIndex((entry) => entry.kind === PREVIEW);
    expect(view[at]).toMatchObject({ id: "preview-u", text: "http://localhost:5173/" });
    expect(view[at + 1]!.kind).toBe("turnSummary");
    // A turn without a page has no card; a running one waits until it ends.
    expect(
      turnView(rows.slice(0, 1).concat(rows.slice(3)), new Set(), { now: 10 }).some((entry) => entry.kind === PREVIEW),
    ).toBe(false);
    expect(
      turnView(rows.slice(0, 3), new Set(), { now: 10, working: true }).some((entry) => entry.kind === PREVIEW),
    ).toBe(false);
  });
});
