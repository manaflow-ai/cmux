// l10n-allow-file: test fixture commands and descriptions, not shipped UI.
// The agent turn as the ChatGPT/Codex app draws it (Leo and Lawrence, 2026-10-20): a finished run
// that is one group folds to its closed line ("Ran 3 commands") between the paragraphs; a finished
// call's check and time show only on hover, a failure keeps its red mark; a command reads as what
// it does (Claude Code's Bash description) and never as the bare tool name "Bash".
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { CommandRow } from "../src/agent-session/acpmux/conversation/CommandRow";
import { ToolRow } from "../src/agent-session/acpmux/conversation/ToolRow";
import { ToolRows } from "../src/agent-session/acpmux/conversation/TurnRows";
import { callDescription } from "../src/agent-session/acpmux/direct";
import { resetTranscriptDisclosure } from "../src/agent-session/acpmux/conversation/transcriptDisclosure";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const shell = (id: string, extra: Partial<Tool> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: {
    id,
    title: "Bash",
    kind: "execute",
    status: "completed",
    command: `echo ${id}`,
    startedAt: 1_000,
    endedAt: 3_500,
    ...extra,
  },
});
const run = (items: AcpmuxActivity[], extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: "run",
  version: 1,
  at: 1,
  kind: "activity",
  items,
  ...extra,
});
const words = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

test("a finished run that is one group folds to its closed line", () => {
  resetTranscriptDisclosure();
  const items = [shell("a"), shell("b"), shell("c")];
  const folded = renderToStaticMarkup(<ToolRows row={run(items, { settled: true, foldRun: true })} />);
  expect(words(folded)).toBe("Ran 3 commands");
  expect(folded).toContain('aria-expanded="false"');
  // Off (or a run still going), the group lists its calls.
  const listed = renderToStaticMarkup(<ToolRows row={run(items)} />);
  expect(words(listed)).toContain("echo a");
  expect(listed).toContain('aria-expanded="true"');
});

test("a command reads as its description, the raw line only in its Shell block", () => {
  const html = renderToStaticMarkup(
    <CommandRow item={shell("x", { command: 'export PATH="/a:$PATH"; bun test', description: "Run the web tests" })} />,
  );
  expect(words(html)).toContain("Run the web tests");
  expect(html).not.toContain("export PATH");
  const plain = renderToStaticMarkup(<CommandRow item={shell("y")} />);
  expect(words(plain)).toContain("Ran echo y");
});

test("a lone shell call reads as its description, and never as the bare tool name", () => {
  const described = renderToStaticMarkup(<ToolRow item={shell("x", { description: "List the build folder" })} />);
  expect(words(described)).toContain("List the build folder");
  const bare = renderToStaticMarkup(<ToolRow item={shell("y", { command: undefined })} />);
  expect(words(bare)).toContain("Ran a command");
  expect(words(bare)).not.toMatch(/\bBash\b/);
  const running = renderToStaticMarkup(
    <ToolRow item={shell("z", { command: undefined, status: "in_progress", endedAt: undefined })} />,
  );
  expect(words(running)).toContain("Running a command");
});

test("Claude Code's Bash description is read from the call's raw input", () => {
  expect(callDescription({ command: "ls", description: " List files " })).toBe("List files");
  expect(callDescription({ command: "ls" })).toBeUndefined();
  expect(callDescription({ description: 42 })).toBeUndefined();
});

test("a finished call draws its check and time; a failure its red mark", () => {
  const ok = renderToStaticMarkup(<CommandRow item={shell("ok")} />);
  expect(ok).toContain("cv-command__ok");
  expect(ok).toContain('class="cv-command__time">2.5s');
  const failed = renderToStaticMarkup(<CommandRow item={shell("bad", { status: "failed", exitCode: 1 })} />);
  expect(failed).toContain("cv-command__failed");
  expect(failed).not.toContain("cv-command__ok");
  const lone = renderToStaticMarkup(
    <ToolRow item={shell("lone", { command: undefined, title: "Fetch docs", kind: "fetch" })} />,
  );
  expect(lone).toContain("cv-command__ok");
  expect(lone).toContain('class="cv-command__time">2.5s');
});

test("the check and time show only on hover or focus; the failure mark always", async () => {
  const css = await Bun.file(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
  ).text();
  expect(css).toMatch(/\.cv-tool :is\(\.cv-command__ok, \.cv-command__time\) \{\s*opacity: 0;/);
  expect(css).toMatch(
    /\.cv-tool:is\(:hover, :focus-visible\) :is\(\.cv-command__ok, \.cv-command__time\) \{\s*opacity: 1;/,
  );
  expect(css).not.toMatch(/cv-command__failed[^{]*\{[^}]*opacity: 0/);
  expect(css).not.toMatch(/cv-tool__failed[^{]*\{[^}]*opacity: 0/);
});

// Leo (2026-10-21): "let's only show the green/red checkmark + time on hover for ours". A failed
// call that is not a shell still says so in red at rest; a running one keeps its spinner.
test("a failed tool call keeps its red mark at rest; a running one its spinner", () => {
  const failed = renderToStaticMarkup(
    <ToolRow item={shell("bad", { command: undefined, title: "Fetch docs", kind: "fetch", status: "failed" })} />,
  );
  expect(failed).toContain('class="cv-tool__failed"');
  expect(failed).not.toContain("cv-command__ok");
  const running = renderToStaticMarkup(
    <CommandRow item={shell("live", { status: "in_progress", endedAt: undefined })} />,
  );
  expect(running).toContain("cv-spinner");
  expect(running).not.toContain("cv-command__ok");
  expect(running).not.toContain("cv-command__time");
});

test("the hover check and time fade as a message's hover row does", async () => {
  const css = await Bun.file(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
  ).text();
  expect(css).toMatch(
    /\.cv-tool :is\(\.cv-command__ok, \.cv-command__time\) \{\s*transition: opacity var\(--cv-actions-out\)/,
  );
  expect(css).toMatch(
    /\.cv-tool:hover :is\(\.cv-command__ok, \.cv-command__time\) \{\s*transition: opacity var\(--cv-actions-in\) var\(--cv-actions-ease\) var\(--cv-actions-in-delay\)/,
  );
});

test("a floating row Copy reserves the tool chevron slot", async () => {
  const css = await Bun.file(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
  ).text();
  expect(css).toContain('.acpmux-row[data-floating-copy="true"] > .cv-tools > .cv-tool');
  expect(css).toMatch(/\.acpmux-row\[data-floating-copy="true"\] > \.acpmux-row__copy \{\s*right: 24px;/);
});
