// l10n-allow-file: test fixtures (commands, descriptions and outputs), not shipped UI.
// A run of tool calls reads as Claude Code desktop summarizes one (Leo, 2026-11-03: "claude code
// desktop's summarization of tool calls/parsing of them seem kinda good?"): a header that counts what
// happened, "Finished 2 background tasks and ran 3 commands (1 failed)"; one row per call titled by its
// description, a failed one with "Failed" right after its words and before its chevron; opened, the
// command, then "Exit code N", then the output; a background command's end noted as "Background
// command completed <command>".
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { BackgroundTaskNote } from "../src/agent-session/acpmux/conversation/BackgroundTaskNote";
import { readFileSync } from "node:fs";
import { CommandRow } from "../src/agent-session/acpmux/conversation/CommandRow";
import { InStep } from "../src/agent-session/acpmux/conversation/toolFailureCauseModel";
import { ToolGroupRow } from "../src/agent-session/acpmux/conversation/ToolGroupRow";
import { ToolRun } from "../src/agent-session/acpmux/conversation/ToolRun";
import { toolGroupLabel } from "../src/agent-session/acpmux/conversation/toolGroups";
import { toolRunSummary } from "../src/agent-session/acpmux/conversation/toolRunSummary";
import { translate } from "../src/agent-session/acpmux/i18n";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const css = readFileSync(new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url), "utf8");
let ids = 0;
const shell = (description: string | undefined, extra: Partial<Tool> = {}): AcpmuxActivity => {
  const tool: Tool = {
    id: `call-${(ids += 1)}`,
    title: "Bash",
    kind: "execute",
    status: "completed",
    command: "make check",
    ...(description ? { description } : {}),
    ...extra,
  };
  return { kind: "tool", text: tool.title, tool };
};
const words = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/&#x27;/g, "'")
    .replace(/\s+/g, " ")
    .trim();

const run = () => [
  shell("Find the retry references", { background: { state: "completed", endedAt: 2 } }),
  shell("Read the fixture list", { status: "failed", output: "Exit code 1\nls: fixtures: No such file" }),
  shell("Check both workers", { background: { state: "failed", endedAt: 3 } }),
];

test("a run's header counts its finished background tasks first, then what it ran, then (N failed)", () => {
  expect(toolRunSummary(translate, run())).toBe("Finished 2 background tasks and ran 3 commands");
  expect(toolGroupLabel(translate, "commands", run())).toBe("Finished 2 background tasks and ran 3 commands");
  // A run with no background task reads as before.
  expect(toolGroupLabel(translate, "commands", [shell("a"), shell("b")])).toBe("Ran 2 commands");
  // A background command still running is no finished task.
  expect(toolRunSummary(translate, [shell("a", { background: { state: "running" } }), shell("b")])).toBe(
    "Ran 2 commands",
  );
  const group = words(renderToStaticMarkup(<ToolGroupRow kind="commands" items={run()} disclosureKey="g" folded />));
  expect(group).toContain("Finished 2 background tasks and ran 3 commands (2 failed)");
  const line = words(
    renderToStaticMarkup(
      <ToolRun items={run()} disclosureKey="r">
        {null}
      </ToolRun>,
    ),
  );
  expect(line).toContain("Finished 2 background tasks and ran 3 commands (2 failed)");
});

test("a background command keeps its prose description and gains a completion status", () => {
  const description = "Create worktree for lane";
  const done = renderToStaticMarkup(
    <CommandRow item={shell(description, { background: { state: "completed", endedAt: 2 } })} />,
  );
  expect(words(done)).toContain(`${description} · Finished`);
  expect(done).not.toMatch(/<code\b/);
  expect(words(done)).not.toContain("make check");
  const live = renderToStaticMarkup(<CommandRow item={shell(description, { background: { state: "running" } })} />);
  expect(words(live)).toContain(description);
  expect(words(live)).not.toContain("Finished");
});

test("while a background command runs, an opened run lists it as a step, with no count line", () => {
  const items = [
    shell("a", { background: { state: "completed", endedAt: 1 } }),
    shell("b", { background: { state: "failed", endedAt: 1 } }),
    shell("c", { background: { state: "running" } }),
  ];
  const group = renderToStaticMarkup(<ToolGroupRow kind="commands" items={items} disclosureKey="bg-open" />);
  // Leo, 2026-11-06: "why doesn't it just show it normally like the other ones?"
  expect(group).not.toContain("cv-bgstatus");
  expect(group.replace(/<[^>]+>/g, "")).not.toContain("1 running");
  // One step per call, the running one among them.
  expect(group.match(/class="cv-step"/g)).toHaveLength(3);
});

test("a failed call shows its readable label, failure tag and chevron in order", () => {
  const failing = shell(undefined, { status: "failed", output: "Exit code 1\nls: nope" });
  // A step of an opened run is tagged "failed" (drawn "Failed"); its Shell block names the exit.
  const step = renderToStaticMarkup(
    <InStep.Provider value>
      <CommandRow item={failing} />
    </InStep.Provider>,
  );
  // The failure tag follows the readable label and precedes the chevron.
  expect(words(step)).toMatch(/Running tests.*failed/);
  expect(step).toMatch(/class="cv-command__failed"[^>]*>failed<.*cv-tool__chevron/s);
  expect(step).not.toContain("make check");
  expect(step).not.toMatch(/cv-command__meta[^>]*>[^]*cv-command__failed/);
  // A lone command keeps its exit word, in the same place.
  const lone = renderToStaticMarkup(<CommandRow item={failing} />);
  expect(words(lone)).toMatch(/Running tests.*Exit 1/);
  expect(lone).toMatch(/class="cv-command__failed"[^>]*>Exit 1<.*cv-tool__chevron/s);
  // A background command that failed says so the same way.
  const background = renderToStaticMarkup(
    <CommandRow item={shell("Check both workers", { background: { state: "failed", endedAt: 3 } })} />,
  );
  expect(background).toMatch(/class="cv-command__failed"[^>]*>failed</);
  // The tag reads "Failed" on screen.
  expect(css).toMatch(
    /\.cv-command > \.cv-command__failed::first-letter,\s*\.cv-tool > \.cv-tool__failed:not\(\.cv-tool__icon\)::first-letter \{\s*text-transform: uppercase;/,
  );
  const successful = renderToStaticMarkup(<CommandRow item={shell(undefined)} />);
  expect(words(successful)).toContain("Ran tests with make");
  expect(successful).not.toContain("cv-command__failed");
});

test("background notices use the description, then a command summary, followed by the outcome", () => {
  const task = { toolCallId: "x", command: "pytest -x" };
  const html = renderToStaticMarkup(
    <BackgroundTaskNote task={{ ...task, description: "Check the worktree", state: "completed" }} />,
  );
  expect(words(html)).toContain("Check the worktree · Finished");
  expect(html).not.toContain(task.command);
  const failed = renderToStaticMarkup(<BackgroundTaskNote task={{ ...task, state: "failed" }} />);
  expect(words(failed)).toContain("Running tests · Failed");
  expect(failed).not.toContain("<code");
});
