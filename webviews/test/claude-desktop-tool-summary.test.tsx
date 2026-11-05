// l10n-allow-file: test fixtures (commands, descriptions and outputs), not shipped UI.
// A run of tool calls reads as Claude Code desktop summarizes one (Leo, 2026-11-03: "claude code
// desktop's summarization of tool calls/parsing of them seem kinda good?"): a header that counts what
// happened, "Finished 2 background tasks, ran 3 commands (1 failed)"; one row per call titled by its
// description, a failed one with "Failed" right after its words and before its chevron; opened, the
// command, then "Exit code N", then the output; a background command's end noted as "Background
// command completed <command>".
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { BackgroundTaskNote } from "../src/agent-session/acpmux/conversation/BackgroundTaskNote";
import { backgroundCounts, backgroundStatusParts } from "../src/agent-session/acpmux/conversation/BackgroundStatusLine";
import { readFileSync } from "node:fs";
import { CommandRow } from "../src/agent-session/acpmux/conversation/CommandRow";
import { InStep } from "../src/agent-session/acpmux/conversation/ToolFailureCause";
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
  expect(toolRunSummary(translate, run())).toBe("Finished 2 background tasks, ran 3 commands");
  expect(toolGroupLabel(translate, "commands", run())).toBe("Finished 2 background tasks, ran 3 commands");
  // A run with no background task reads as before.
  expect(toolGroupLabel(translate, "commands", [shell("a"), shell("b")])).toBe("Ran 2 commands");
  // A background command still running is no finished task.
  expect(toolRunSummary(translate, [shell("a", { background: { state: "running" } }), shell("b")])).toBe(
    "Ran 2 commands",
  );
  const group = words(renderToStaticMarkup(<ToolGroupRow kind="commands" items={run()} disclosureKey="g" folded />));
  expect(group).toContain("Finished 2 background tasks, ran 3 commands (2 failed)");
  const line = words(
    renderToStaticMarkup(
      <ToolRun items={run()} disclosureKey="r">
        {null}
      </ToolRun>,
    ),
  );
  expect(line).toContain("Finished 2 background tasks, ran 3 commands (2 failed)");
});

test("a command that finished in the background reads Background command completed, then its description", () => {
  const html = renderToStaticMarkup(
    <CommandRow item={shell("Find the retry references", { background: { state: "completed", endedAt: 2 } })} />,
  );
  expect(html).toMatch(/class="cv-command__lead"[^>]*>Background command completed<\/span>/);
  expect(words(html)).toContain("Background command completed Find the retry references");
  // Still running, it is its description alone.
  const live = renderToStaticMarkup(<CommandRow item={shell("Start the API", { background: { state: "running" } })} />);
  expect(live).not.toContain("cv-command__lead");
});

test("while a background command runs, an opened run says how its background commands stand", () => {
  const items = [
    shell("a", { background: { state: "completed", endedAt: 1 } }),
    shell("b", { background: { state: "failed", endedAt: 1 } }),
    shell("c", { background: { state: "running" } }),
  ];
  const parts = backgroundStatusParts(translate, backgroundCounts(items)!);
  expect(parts.map((part) => part.text).join(", ")).toBe("1 background command completed, 1 failed, 1 running");
  expect(parts.find((part) => part.failed)?.text).toBe("1 failed");
  expect(
    backgroundStatusParts(translate, backgroundCounts([items[0]!, items[2]!])!)
      .map((part) => part.text)
      .join(", "),
  ).toBe("1 background command completed, 1 running");
  // Once none runs, the line goes: the head counts what finished.
  expect(backgroundCounts([items[0]!, items[1]!])).toBeUndefined();
  const group = renderToStaticMarkup(<ToolGroupRow kind="commands" items={items} disclosureKey="bg-open" />);
  expect(group).toMatch(/class="cv-tool__failed">1 failed</);
  expect(group.replace(/<[^>]+>/g, "")).toContain("1 background command completed, 1 failed, 1 running");
  // Its words are one line box inside the flex row: as flex items, the separators' spaces collapse
  // ("completed,1 failed,1 running", seen in a DEV build).
  expect(group).toMatch(/<output class="cv-bgstatus"[^>]*><span class="cv-bgstatus__text"><span>1 background/);
  // It is no step: the opened run still lists one step per call.
  expect(group.match(/class="cv-step"/g)).toHaveLength(3);
});

test("a failed call's row is its description, then its failure tag, then its chevron", () => {
  const failing = shell("Read the fixture list", { status: "failed", output: "Exit code 1\nls: nope" });
  // A step of an opened run is tagged "failed" (drawn "Failed"); its Shell block names the exit.
  const step = renderToStaticMarkup(
    <InStep.Provider value>
      <CommandRow item={failing} />
    </InStep.Provider>,
  );
  // Title, the red tag, the chevron, in that order; the tag is not in the trailing column.
  expect(step).toMatch(/Read the fixture list<\/span>.*class="cv-command__failed"[^>]*>failed<.*cv-tool__chevron/s);
  expect(step).not.toMatch(/cv-command__meta[^>]*>[^]*cv-command__failed/);
  // A lone command keeps its exit word, in the same place.
  expect(renderToStaticMarkup(<CommandRow item={failing} />)).toMatch(
    /Read the fixture list<\/span>.*class="cv-command__failed"[^>]*>Exit 1<.*cv-tool__chevron/s,
  );
  // A background command that failed says so the same way.
  const background = renderToStaticMarkup(
    <CommandRow item={shell("Check both workers", { background: { state: "failed", endedAt: 3 } })} />,
  );
  expect(background).toMatch(/class="cv-command__failed"[^>]*>failed</);
  // The tag reads "Failed" on screen.
  expect(css).toMatch(
    /\.cv-command > \.cv-command__failed::first-letter,\s*\.cv-tool > \.cv-tool__failed:not\(\.cv-tool__icon\)::first-letter \{\s*text-transform: uppercase;/,
  );
  // Without a description the row keeps its command.
  expect(words(renderToStaticMarkup(<CommandRow item={shell(undefined)} />))).toContain("make check");
});

test("a background command's end reads Background command completed, its command in full ink", () => {
  const html = renderToStaticMarkup(
    <BackgroundTaskNote task={{ toolCallId: "x", command: "pytest -x", state: "completed" }} />,
  );
  expect(html).toMatch(/class="cv-bgtask__state"[^>]*>Background command completed<\/span>/);
  expect(html).toMatch(/class="cv-bgtask__command"[^>]*>pytest -x<\/code>/);
  const failed = renderToStaticMarkup(
    <BackgroundTaskNote task={{ toolCallId: "y", command: "pytest -x", state: "failed" }} />,
  );
  expect(words(failed)).toContain("Background command failed pytest -x");
});
