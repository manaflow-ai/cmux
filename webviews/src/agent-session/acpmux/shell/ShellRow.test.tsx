import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { ShellRow } from "./ShellRow";
import type { ShellRun } from "./shellRuns";
import { JSDOM } from "jsdom";

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

const markup = (shell: ShellRun, expanded = false) =>
  renderToStaticMarkup(<ShellRow row={shellRow(shell)} expanded={expanded} onToggleActivity={() => undefined} />);

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

test("a failed command presents a readable error and keeps raw diagnostics under closed Details", () => {
  const diagnostic = "zsh:1: no such file or directory: /fast";
  const document = new JSDOM(markup(run({ command: "/fast", status: "failed", exitCode: 127, output: diagnostic })))
    .window.document;
  const note = document.querySelector('[role="alert"]')!;
  expect(note.querySelector(".text-fg")!.textContent).toBe("The command could not run. Open Details to see the error.");
  const details = note.querySelector("details")!;
  expect(details.open).toBe(false);
  expect(details.querySelector("pre")!.textContent).toBe(diagnostic);
  expect(note.childNodes[0]!.textContent).not.toContain("zsh:");
});

test("separates partial output from the host error in Details", () => {
  const document = new JSDOM(markup(run({ status: "failed", output: "partial-output", error: "host-error" }))).window
    .document;
  expect(document.querySelector("details pre")!.textContent).toBe("partial-output\nhost-error");
});

test("keeps a truncated empty output diagnostic visible", () => {
  const document = new JSDOM(markup(run({ output: "", truncated: true }))).window.document;
  expect(document.querySelector("pre")!.textContent).toBe("…");
});

test("failed truncated empty output keeps Details available", () => {
  const document = new JSDOM(markup(run({ status: "failed", output: "", truncated: true }))).window.document;
  expect(document.querySelector("details pre")!.textContent).toBe("…");
});

test("failed long output keeps Show all inside Details and can reveal the complete diagnostic", () => {
  const output = Array.from({ length: 10 }, (_, n) => `line ${n + 1}`).join("\n");
  const collapsed = new JSDOM(markup(run({ status: "failed", output }))).window.document;
  expect(collapsed.querySelector("details .acpmux-shell-block-more")!.textContent).toBe("Show all output");
  const expanded = new JSDOM(markup(run({ status: "failed", output }), true)).window.document;
  expect(expanded.querySelector("details pre")!.textContent).toContain("line 1\n");
});
