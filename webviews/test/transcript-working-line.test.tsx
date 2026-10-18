// l10n-allow-file: test fixture tool titles, not shipped UI.
// The running turn's status line, as Claude desktop draws it (#21604 row 2,
// transcript-task-list-in-progress.png): a small animated mark, then what the agent is doing now.
// While a tool call runs the line names it and keeps the turn's time beside it; between calls it
// reads "Working for 42s" as before, and before any work "Thinking" carries the same mark.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { WorkingFor } from "../src/agent-session/acpmux/conversation/WorkingFor";
import { turnView, WORKING } from "../src/agent-session/acpmux/conversation/turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const call = (id: string, status: string) => ({
  kind: "tool",
  text: "",
  tool: { id, title: id, kind: "execute", status },
});

function statusLine(calls: ReturnType<typeof call>[]): AcpmuxRow {
  const live = [row("u", "user"), row("a", "assistant", { text: "On it." }), row("run", "activity", { items: calls })];
  const status = turnView(live, new Set(), { working: true }).find((entry) => entry.kind === WORKING);
  if (!status) throw new Error("no status line");
  return status;
}

const drawn = (status: AcpmuxRow) => renderToStaticMarkup(<WorkingFor row={status} now={() => status.at + 26_000} />);
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

test("while a call runs, the status line names it beside the turn's time", () => {
  const status = statusLine([call("git log", "completed"), call("bun test", "in_progress")]);
  expect(status.doing).toBe("bun test");
  const html = drawn(status);
  expect(text(html)).toBe("bun test 26s");
  expect(html).toContain("cv-working-mark");
});

test("between calls, the line reads Working for, with the same mark", () => {
  const status = statusLine([call("git log", "completed")]);
  expect(status.doing).toBeUndefined();
  const html = drawn(status);
  expect(text(html)).toBe("Working for 26s");
  expect(html).toContain("cv-working-mark");
});

test("Thinking carries the mark too", () => {
  expect(renderToStaticMarkup(<Thinking />)).toContain("cv-working-mark");
});

test("a call whose title is its raw input reads as a label, not JSON", () => {
  const read = {
    kind: "tool",
    text: "",
    tool: {
      id: "r",
      title: '{"file_path":"src/app.ts"}',
      kind: "read",
      status: "in_progress",
      inputSummary: '{"file_path":"src/app.ts"}',
    },
  };
  const status = statusLine([read]);
  expect(status.doing).toContain("app.ts");
  expect(status.doing).not.toContain("{");
});
