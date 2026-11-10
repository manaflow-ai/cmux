// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// Opening and closing a big tool call at the very bottom of a long chat (Leo, 2026-11-07: "i think
// the expansion of tool calls at the bottom of the transcript sometimes gets unreliable...
// sometimes it doesn't play ythe animation, and also, sometimes it lags when i open it"). The last
// turn ran a command that printed a long log and edited a long file, then replied. Every open and
// close here plays the shared fold (fold.ts), whether the turn is over, still streaming, or just
// sent; test/tool-fold-bottom-browser.test.ts reads every painted frame of each.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, CWD, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";

const paragraph = (index: number) =>
  `Step ${index}. The fetch helper retries every failure the same way, so a 404 waits through three ` +
  "backoffs before it fails. I read how the helper decides to retry and who calls it.";

const earlier = Array.from({ length: 8 }, (_, index) => {
  const minutes = 80 - index * 8;
  return [
    user(`Check part ${index + 1} of the retry loop`, minutes),
    assistant([paragraph(index * 2 + 1), paragraph(index * 2 + 2)].join("\n\n"), minutes - 1),
  ];
}).flat();

/// A test log long enough that drawing all of it costs real time: the 400-line tail a cut Shell card
/// holds, every line distinct.
const LOG = Array.from(
  { length: 1_200 },
  (_, index) =>
    `ok ${index + 1} - fetch retries case ${index + 1} (${(index * 37) % 997} ms) src/net/fetch.test.ts:${index + 10}`,
).join("\n");

const fileLines = (count: number, tag: string) =>
  Array.from(
    { length: count },
    (_, index) => `export const ${tag}${index} = retry(fetchCase${index}, { tries: 3 });`,
  ).join("\n");

const bigCommand = tool("bun test fetch", "execute", "completed", {
  command: "bun test fetch",
  description: "Run the fetch tests",
  output: LOG,
  exitCode: 0,
});
const bigEdit = tool("Edit src/net/cases.ts", "edit", "completed", {
  diffs: [{ path: `${CWD}/src/net/cases.ts`, oldText: fileLines(300, "before"), newText: fileLines(300, "after") }],
});

const head = [...earlier, user("Run the fetch tests, then rename every case", 6)];
const doneRows = [
  ...head,
  activity([bigCommand], 5, { id: "fold-bottom-command" }),
  activity([bigEdit], 4.5, { id: "fold-bottom-edit" }),
  assistant("All 1,200 fetch cases pass, and every case is renamed.", 4, { id: "fold-bottom-reply" }),
  summary(3.9, { status: "completed", durationMs: 21_000, toolCount: 2 }),
];

/// A running turn: the same calls, with the reply still coming.
const runningRows = (words: number) => [
  ...head,
  activity([bigCommand], 5, { id: "fold-bottom-command" }),
  activity([bigEdit], 4.5, { id: "fold-bottom-edit" }),
  assistant(Array.from({ length: words }, (_, index) => `word${index}`).join(" "), 4, {
    id: "fold-bottom-reply",
    version: words,
  }),
];

declare global {
  interface Window {
    /** The streaming scene: delivers the reply's next words, as acpmux does while a turn runs. */
    cmuxGalleryStream?: () => void;
    /** The after-send scene: delivers the person's next prompt and the turn it starts. */
    cmuxGallerySend?: () => void;
  }
}

/// Opens the finished turn's "Worked for" line, so its calls draw as rows, then puts the view at the
/// transcript's very bottom, as the reader's wheel does.
const atBottom: Play = async (ctx) => {
  const command = () => ctx.document.querySelector('[data-row-id="fold-bottom-command"] button.cv-tool');
  const worked = () => [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked")].at(-1);
  await ctx.waitFor(() => command() ?? worked(), { capMs: 10_000 });
  if (!command() && worked()?.getAttribute("aria-expanded") === "false") {
    worked()!.click();
    await ctx.waitFor(command, { capMs: 10_000 });
  }
  const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) return;
  scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true }));
  scroller.scrollTop = scroller.scrollHeight;
  scroller.dispatchEvent(new Event("scroll"));
};

const armStream: Play = async (ctx) => {
  await atBottom(ctx);
  const view = ctx.document.defaultView!;
  let words = 12;
  view.cmuxGalleryStream = () => {
    words += 3;
    view.cmuxAcpmuxBridge?.receive(
      structuredClone(chat(runningRows(words), { title: "Fetch tests", isWorking: true })),
    );
  };
};

/// Before the send: the same long chat, its last turn a short answer.
const beforeSend = [
  ...earlier,
  user("Is the fetch suite green?", 7),
  assistant("Yes, the fetch suite passed on the last run.", 6.5),
  summary(6.4, { status: "completed", durationMs: 4_000, toolCount: 0 }),
];

/// Sends the next prompt; the turn it starts runs the two calls at once, under the sent prompt.
const armSend: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-row"), { capMs: 10_000 });
  const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
  if (scroller) {
    scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true }));
    scroller.scrollTop = scroller.scrollHeight;
    scroller.dispatchEvent(new Event("scroll"));
  }
  const view = ctx.document.defaultView!;
  view.cmuxGallerySend = () =>
    view.cmuxAcpmuxBridge?.receive(
      structuredClone(
        chat(
          [
            ...beforeSend,
            user("Run the fetch tests, then rename every case", 1, { id: "fold-bottom-sent" }),
            activity([bigCommand], 0.9, { id: "fold-bottom-command" }),
            activity([bigEdit], 0.8, { id: "fold-bottom-edit" }),
          ],
          { title: "Fetch tests", isWorking: true },
        ),
      ),
    );
};

export default agentPaneEntry({
  id: "agent-pane.tool-fold-bottom",
  title: "A big tool call opened at the bottom",
  area: "Agent pane",
  height: 640,
  covers: ["agent-session/acpmux/conversation/fold.ts", "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript"],
  variants: {
    idle: {
      note: "Scrolled to the very bottom of a finished turn: a command with a 1,200-line log and a 300-line edit. Each opens and closes with the fold, even when drawing what opened takes the page more than a frame.",
      snapshot: chat(doneRows, { title: "Fetch tests" }),
      play: atBottom,
    },
    streaming: {
      note: "The same calls while the reply still streams in under them, the view following the end.",
      snapshot: chat(runningRows(12), { title: "Fetch tests", isWorking: true }),
      play: armStream,
    },
    "after-send": {
      note: "Right after the person sent the next prompt: the turn it starts ran the two calls under it.",
      snapshot: chat(beforeSend, { title: "Fetch tests" }),
      play: armSend,
    },
  },
});
