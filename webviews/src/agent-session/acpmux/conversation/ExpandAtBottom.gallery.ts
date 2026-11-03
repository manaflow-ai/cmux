// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// Opening a line with the transcript at its very bottom (Leo, 2026-11-02: "YOU EXPAND UP WHILE YOUR
// SCCROLL IS AT THE VERY BOTTOM AKA YOU FUCKING PUSH THE TEXT UP VISUALLY INSTEAD OF EXPANDING DOWN
// LIKE USUAL / JUST THAT CASE"). A long chat whose last turn ran two commands under "Ran 2 commands"
// and wrote a short reply after them, scrolled to its end. Opening the group there keeps the bottom
// where it is and pushes everything above it up (App.tsx `beginBottomStackFold`); anywhere else the
// line stays put and its body grows down (transcript-expand-at-bottom.test.ts).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";

const command = (description: string, line: string, output: string) =>
  tool(line, "execute", "completed", { command: line, description, output, exitCode: 0 });

const paragraph = (index: number) =>
  `Step ${index}. The fetch helper retries every failure the same way, so a 404 waits through three ` +
  "backoffs before it fails. I read how the helper decides to retry and who calls it.";

const earlier = Array.from({ length: 6 }, (_, index) => {
  const minutes = 60 - index * 8;
  return [
    user(`Check part ${index + 1} of the retry loop`, minutes),
    assistant([paragraph(index * 2 + 1), paragraph(index * 2 + 2)].join("\n\n"), minutes - 1),
  ];
}).flat();

const log = Array.from({ length: 12 }, (_, index) => `ok ${index + 1} - fetch retries case ${index + 1}`).join("\n");

/// A finished turn that ran a command, above the last one: its "Worked for" line stays closed.
const middle = [
  user("Find the retry helper", 12),
  activity([command("Find the retry helper", "rg -n fetchWithRetry src", log)], 11, { id: "expand-mid-run" }),
  assistant(paragraph(13), 10),
  summary(9.9, { status: "completed", durationMs: 9_000, toolCount: 1 }),
];

const rows = [
  ...earlier,
  ...middle,
  user("Run the fetch tests and show me the log", 6),
  activity(
    [command("Run the fetch tests", "bun test fetch", log), command("Show the test log", "tail -n 12 fetch.log", log)],
    5,
    { id: "expand-at-bottom-run" },
  ),
  assistant("All twelve fetch cases pass.", 4),
  summary(3.9, { status: "completed", durationMs: 21_000, toolCount: 2 }),
];

/// The same chat ending on a long prompt cut to its first lines, with "Show more" under it, and a
/// short reply: a line that is not a tool's, opened at the bottom.
const LONG_PROMPT = Array.from(
  { length: 18 },
  (_, index) => `${index + 1}. Check that case ${index + 1} of the fetch retries fails fast on a client error.`,
).join("\n");
const promptRows = [
  ...earlier,
  user(LONG_PROMPT, 6),
  assistant("All eighteen cases fail fast now.", 4),
  summary(3.9, { status: "completed", durationMs: 21_000, toolCount: 0 }),
];

/// Opens the last turn's "Worked for" line when the turn folded its run under one, then puts the
/// view at the transcript's very bottom, as the reader leaves it after reading the reply.
const atBottom: Play = async (ctx) => {
  const worked = () => [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked")].at(-1);
  const group = () =>
    [...ctx.document.querySelectorAll<HTMLButtonElement>("button.cv-tool.is-toggle[aria-expanded]")].find((node) =>
      /2/.test(node.textContent ?? ""),
    );
  await ctx.waitFor(() => worked() ?? group() ?? ctx.document.querySelector(".cv-user__more"), { capMs: 10_000 });
  if (!group() && worked()?.getAttribute("aria-expanded") === "false") {
    worked()!.click();
    await ctx.waitFor(group, { capMs: 10_000 });
  }
  const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
  if (scroller) scroller.scrollTop = scroller.scrollHeight;
};

export default agentPaneEntry({
  id: "agent-pane.expand-at-bottom",
  title: "Opening a line at the bottom",
  area: "Agent pane",
  height: 640,
  covers: ["agent-session/acpmux/App.tsx#VirtualTranscript", "agent-session/acpmux/conversation/foldAnchor.ts"],
  variants: {
    shipped: {
      note: "Scrolled to the very bottom with “Ran 2 commands” closed. Opening it keeps the bottom pinned and pushes the text above up; away from the bottom it opens down and nothing moves.",
      snapshot: chat(rows, { title: "Fetch tests" }),
      play: atBottom,
    },
    prompt: {
      note: "Scrolled to the very bottom under a long prompt cut to its first lines. Its Show more opens the whole prompt by pushing the text above up; the reply under it stays where it was.",
      snapshot: chat(promptRows, { title: "Fetch tests" }),
      play: atBottom,
    },
  },
});
