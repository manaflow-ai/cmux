import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { ShellRow } from "./ShellRow";
import { ShellActionsContext, type ShellActions } from "./shellRowModel";
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

// Leo, 2026-11-12: "this is a really useless show all 9 lines. i think [another chat app] just lets you scroll,
// straight up?" Every line is drawn, in the shared scroll box, with nothing to expand.
test("a long output draws every line in its scroll box, with no Show all", () => {
  const output = Array.from({ length: 60 }, (_, index) => `line ${index + 1}`).join("\n");
  const html = markup(run({ output }));
  expect(html).toContain("line 1\n");
  expect(html).toContain("line 60");
  expect(html).toContain("cv-scroll-box");
  expect(html).toContain('tabindex="0"');
  expect(html).not.toContain("acpmux-shell-block-cut");
  expect(html).not.toContain("Show all");
  expect(html).not.toContain("aria-expanded");
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
