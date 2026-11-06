import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { ShellActionsContext, ShellRow, type ShellActions } from "./ShellRow";
import type { ShellRun } from "./shellRuns";

const run = (overrides: Partial<ShellRun> = {}): ShellRun => ({
  id: "test-shell",
  command: "printf output",
  startedAt: 1_760_000_000_000,
  status: "done",
  output: "one\ntwo\nthree",
  truncated: false,
  version: 1,
  ...overrides,
});

const shellRow = (shell: ShellRun): AcpmuxRow => ({
  id: `shell-${shell.id}`,
  kind: "userShell",
  at: shell.startedAt,
  version: shell.version,
  shell,
});

const actions: ShellActions = { stop: () => undefined, openInTerminal: () => undefined };

// The owner's pane always provides shell actions (App.tsx); a read-only transcript provides none.
const markup = (shell: ShellRun, expanded = false, given: ShellActions | null = actions) =>
  renderToStaticMarkup(
    <ShellActionsContext.Provider value={given ?? undefined}>
      <ShellRow row={shellRow(shell)} expanded={expanded} onToggleActivity={() => undefined} />
    </ShellActionsContext.Provider>,
  );

test("collapsed long output keeps the tail and offers expansion", () => {
  const output = Array.from({ length: 10 }, (_, index) => `line ${index + 1}`).join("\n");
  const html = markup(run({ output }));
  expect(html).toContain("line 3");
  expect(html).toContain("line 10");
  expect(html).not.toContain("line 2");
  expect(html).toContain("Show all output");
  expect(html).toContain('aria-expanded="false"');
});

test("expanded output shows all lines and offers collapse", () => {
  const output = Array.from({ length: 10 }, (_, index) => `line ${index + 1}`).join("\n");
  const html = markup(run({ output }), true);
  expect(html).toContain("line 1");
  expect(html).toContain("line 10");
  expect(html).not.toContain("acpmux-shell-block-cut");
  expect(html).toContain("Show less");
  expect(html).toContain('aria-expanded="true"');
});

test.each([
  ["running", run({ status: "running" }), "Stop"],
  ["succeeded", run(), "Succeeded"],
  ["failed", run({ status: "failed", exitCode: 2, error: "bad command" }), "Exit code 2"],
  ["stopped", run({ status: "stopped" }), "Stopped"],
] as const)("renders the %s status and terminal action", (_name, shell, status) => {
  const html = markup(shell);
  expect(html).toContain(status);
  expect(html).toContain("Open in terminal");
});

test.each([
  ["running", run({ status: "running" })],
  ["succeeded", run()],
] as const)("read only (no actions), the %s row offers no Stop and no Open in terminal", (_name, shell) => {
  const html = markup(shell, false, null);
  expect(html).not.toContain("acpmux-shell-block-stop");
  expect(html).not.toContain("Open in terminal");
});
