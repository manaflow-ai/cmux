// l10n-allow-file: gallery fixtures (sample prompts, commands and messages), not shipped UI.
// One rule for how every transcript row opens and closes, and one chevron (design/chat-row-anatomy.md;
// Leo, 2026-11-21 05:30Z: "2. inconsistent tool calls collapsing and expanding 3. inconsistent
// chevrons ... 7. background tasks not expandable"). Every row kind on one stage, some opened: a
// thought, a read, two commands, a reply, "Worked for", a received message, a sent call with no
// words, and a "Background task finished: bg-…" line. The variants are the looks the design panel
// weighed; `one-rule` is the default.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import {
  SESSION_ID,
  activity,
  assistant,
  chat,
  row,
  session,
  summary,
  thought,
  tool,
  user,
} from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";

const run = (description: string, command: string, output = "ok\n"): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output, exitCode: 0 });

const SENDER = "lane-box-2/cloud-promote";
const RECEIVED = "backend.yml is green at 4f2a91c; the candidate is ready to promote.";
// A send whose words are not in the transcript (read from a file): its call is all it has.
const SEND = 'acpmux send --no-wait reports:lead "$(cat /tmp/promote/summary.md)"';
const TASK = "bg-53568892f4dd";

const snapshot = () => {
  const base = chat(
    [
      user("Promote the candidate once backend.yml is green.", 20),
      activity(
        [
          thought("Check the last backend.yml run before dispatching anything; a red base would block it."),
          tool("Read deploy/promote.md", "read", "completed"),
          run("Read the lane's last run", "gh run list -w backend.yml -L 1", "completed success 4f2a91c\n"),
          run("Read the candidate's sha", "git rev-parse --short HEAD", "4f2a91c\n"),
        ],
        19.9,
      ),
      assistant("The run is green at 4f2a91c. I started the suite in the background and will report.", 19.8),
      summary(19.7, { status: "completed", durationMs: 11_000, toolCount: 3 }),
      user(RECEIVED, 12, {
        incoming: {
          kind: "message",
          message: { name: SENDER, text: RECEIVED, raw: RECEIVED, sessionId: "s-lane", harness: "claude" },
        },
        untyped: true,
      }),
      activity(
        [
          tool(SEND.slice(0, 120), "execute", "completed", {
            command: SEND,
            description: "Send the summary",
            output: "queued",
          }),
        ],
        11.9,
      ),
      row(BACKGROUND_TURN, 8, {
        id: backgroundTurnRowId("anatomy-bg"),
        background: {
          id: "anatomy-bg",
          trigger: "task_notification",
          running: false,
          quiet: true,
          hasRows: true,
          cause: { kind: "shell", status: "completed", weight: "result", summary: `Background task finished: ${TASK}` },
          source: { command: "bun test test/background-turn-task-opens.test.tsx" },
        },
      }),
      assistant("The suite passed.", 7.9, { inBackground: "anatomy-bg" }),
    ],
    {
      title: "cloud-promote",
      sessions: [
        session({ sessionId: SESSION_ID, title: "cloud-promote", name: "cloud-promote" }),
        session({ sessionId: "s-lane", title: SENDER, name: SENDER }),
      ],
    },
  );
  return { ...base, summary: { ...base.summary!, family: "claude" } };
};

const STYLE_ID = "gallery-row-anatomy";

// The looks before this change: inner calls hid their chevron until hover while group, message and
// failure lines kept theirs; a background task's line drew none; a sent call opened in a card.
const BEFORE = `
.cv-steps > .cv-step > .cv-tool > .cv-tool__chevron,
.cv-message-group__head > .cv-tool__chevron { opacity: 0; }
.cv-steps > .cv-step > .cv-tool:is(:hover, [aria-expanded="true"]) > .cv-tool__chevron { opacity: 1; }
[data-opens="task"] .cv-tool__chevron { display: none; }
.cv-agentmsg__bare {
  margin-inline-start: var(--grid-icon-box);
  padding: var(--grid-cards-padding);
  border-radius: 8px;
  background: var(--ds-surface-card);
  box-shadow: inset 0 0 0 var(--cmux-hairline, 0.5px) color-mix(in srgb, var(--cv-text) 12%, transparent);
}`;
// Every chevron in a left gutter column, before the glyph (the tree view's place).
const GUTTER = `
.cv-tool > .cv-tool__chevron, .cv-agent-activity__control > .cv-tool__chevron { order: -1; margin-inline: 0 4px; }`;
// No cards at all: every opened body is bare at the text column, a message's words as a thought's.
const INLINE = `
.cv-agentmsg__card, .cv-shell { background: none !important; box-shadow: none !important; border-radius: 0 !important; }`;
// Every chevron hidden until the pointer comes, on every row (the inner calls' old rule, everywhere).
const HOVER = `
.cv-tool .cv-tool__chevron { opacity: 0; }
.cv-tool:is(:hover, [aria-expanded="true"]) .cv-tool__chevron { opacity: 1; }`;

/// Opens the rows that hold rows and the rows that hold content, so the stage shows how each opens.
const look =
  (css: string, opensTask = true): Play =>
  async (ctx) => {
    ctx.document.getElementById(STYLE_ID)?.remove();
    if (css) {
      const style = ctx.document.createElement("style");
      style.id = STYLE_ID;
      style.textContent = css;
      ctx.document.head.append(style);
    }
    const line = (words: RegExp) => () =>
      [...ctx.document.querySelectorAll<HTMLButtonElement>("button[aria-expanded]")].find((node) =>
        words.test(node.textContent ?? ""),
      );
    // Opens a line with a staged click (ctx.click), as the person would: the click declares the expand
    // of what it opens, and the rows it pushes down. A bare element.click() inside a wait declares
    // nothing, so the fold opening below it counted as undeclared moves.
    const press = async (button: HTMLButtonElement) => {
      button.setAttribute("data-row-anatomy-press", "");
      try {
        await ctx.click({ selector: "[data-row-anatomy-press]" });
      } finally {
        button.removeAttribute("data-row-anatomy-press");
      }
    };
    const open = async (words: RegExp) => {
      const find = line(words);
      await ctx.waitFor(find, { capMs: 10_000 });
      if (find()?.getAttribute("aria-expanded") === "false") await press(find()!);
      await ctx.waitFor(() => find()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
    };
    await open(/^Worked for/);
    await open(/Ran 2 commands|Explored|Read .* and ran|Ran \d|Read \d/);
    await open(/Listed workflow runs|Read the lane's last run/);
    // A message line's toggle is the line's cover, with no words of its own.
    const sent = () => ctx.document.querySelector<HTMLButtonElement>(".cv-sent-msg button.cv-agentmsg__toggle");
    await ctx.waitFor(sent, { capMs: 10_000 });
    if (sent()?.getAttribute("aria-expanded") === "false") await press(sent()!);
    await ctx.waitFor(() => sent()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
    if (opensTask) {
      await open(/Background task finished/);
      await ctx.waitFor(
        () => ctx.document.querySelector("[data-opens='task'] ~ * .cv-shell, .cv-background-turn__task .cv-shell"),
        {
          capMs: 10_000,
        },
      );
    }
  };

const variants: Record<string, AgentPaneVariant> = {
  "one-rule": {
    note: "Selected default. Every row that opens shows its chevron at rest, after its words, in the quiet tone; one that opens nothing shows none. Rows that hold rows open them inline at the child step; rows that hold content open one body (a thought's words, a message's card, a command's card). A background task's line opens to its command, its end and its last lines.",
    snapshot: snapshot(),
    play: look(""),
  },
  before: {
    note: "Before: inner calls hide their chevron until hover while group, message and failure lines keep theirs; the background task's line has no chevron and opens nothing; a sent call with no words opens as a row inside a card.",
    snapshot: snapshot(),
    play: look(BEFORE, false),
  },
  gutter: {
    note: "The one rule with every chevron in a left gutter, before the glyph: lines up in one column, but moves Leo's after-the-words pick (2026-11-03) and crowds the glyph.",
    snapshot: snapshot(),
    play: look(GUTTER),
  },
  "all-inline": {
    note: "The one rule with no cards at all: a message's words and a command's output open bare at the text column, as a thought does. Quieter; loses the card that marks where a body ends (Leo's 2026-11-07 card pick).",
    snapshot: snapshot(),
    play: look(INLINE),
  },
  "hover-only": {
    note: "Every chevron hidden until the pointer comes, on every row: consistent, but a reader can't tell which rows open without sweeping the pointer over them.",
    snapshot: snapshot(),
    play: look(HOVER),
  },
};

export default agentPaneEntry({
  id: "agent-pane.row-anatomy",
  title: "Row anatomy: one open and close rule and one chevron for every row kind",
  area: "Agent pane",
  height: 900,
  widths: { narrow: 420, normal: 760, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/conversation.css",
    "agent-session/acpmux/conversation/MessageGroupHead.css",
    "agent-session/acpmux/conversation/AgentMessageRow.css",
    "agent-session/acpmux/conversation/BackgroundTurnLine.tsx",
  ],
  variants,
});
