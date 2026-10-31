// l10n-allow-file: gallery fixtures (a sample prompt and message), not shipped UI.
// The copy button in an expanded card's top-right corner (CardCopy.tsx), on the two card kinds that
// draw it: a started sub-session's prompt (SubsessionCallCard.tsx) and another agent's message
// (IncomingMessageCard.tsx). Each look is shown at rest, with the card hovered, and copied. `faint`
// (selected) is a 14px glyph at 45% that goes full on the card's hover and turns into a check;
// `quiet` is a 12px glyph at 30%; `word` says "Copied" beside the check.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { tool } from "../../../gallery/fixtures/acpmux";
import { CardCopyLookContext, CardCopyWriterContext, type CardCopyLook } from "./CardCopy";
import { IncomingMessageLine } from "./IncomingMessageCard";
import { SubsessionCallCard } from "./SubsessionCallCard";
import { subsessionCall } from "./subsessionCalls";
import { resetTranscriptDisclosure, TranscriptDisclosureProvider } from "./transcriptDisclosure";

type Props = { look: CardCopyLook; card: "prompt" | "message" };

const PROMPT = [
  "You are **net-retries**, a lane started by the coordinator.",
  "",
  'The ask, word for word: "the retry banner still flickers when the network comes back".',
  "",
  "1. Find where `RetryBanner` decides to show, and why it shows twice.",
  "2. Fix it in `src/net/retry.ts`, with a test.",
  "",
  "Stop after the PR is open.",
].join("\n");

const MESSAGE =
  "The grid fix is on example/grid-fix; tests pass.\n\nThe grid now reserves its height before the images load, so nothing below it moves.";

const START_ACTIVITY = tool("mcp__cmux-subsessions__start_session", "other", "completed", {
  inputSummary: JSON.stringify({ name: "net-retries", harness: "claude", model: "opus", prompt: PROMPT }),
  output: "Started sub-session net-retries (sessionId sub-retries, depth 1).",
});

type Tool = NonNullable<typeof START_ACTIVITY.tool>;
const START = START_ACTIVITY.tool as Tool;

const DISCLOSURE = "gallery-card-copy";

/// A headless capture has no clipboard to write: the stage's stand-in takes every copy.
const writeCopy = async () => true;

function Stage({ look, card }: Props) {
  useState(() => resetTranscriptDisclosure(DISCLOSURE));
  return (
    <TranscriptDisclosureProvider sessionId={DISCLOSURE}>
      <CardCopyWriterContext.Provider value={writeCopy}>
        <CardCopyLookContext.Provider value={look}>
          <div className="acpmux-shell" style={{ padding: 16, maxWidth: 640 }}>
            {card === "prompt" ? (
              <SubsessionCallCard call={subsessionCall(START)} tool={START} />
            ) : (
              <IncomingMessageLine
                id={`card-copy-${look}`}
                message={{ name: "grid-lane", text: MESSAGE, raw: MESSAGE }}
                onOpen={() => {}}
              />
            )}
          </div>
        </CardCopyLookContext.Provider>
      </CardCopyWriterContext.Provider>
    </TranscriptDisclosureProvider>
  );
}

const PANEL = ".cv-disclosure__panel";
const BUTTON = ".cv-card-copy__button";

/// Opens the card: the one line's toggle (a started sub-session's chevron, when its line opens a chat).
const open: Play = async (ctx) => {
  const toggle =
    ctx.document.querySelector<HTMLButtonElement>(".cv-disclosure__toggle.is-chevron") ??
    ctx.document.querySelector<HTMLButtonElement>(".cv-disclosure__toggle");
  toggle?.click();
  await ctx.waitFor(() => ctx.document.querySelector(BUTTON));
};
const hovered: Play = async (ctx) => {
  await open(ctx);
  await ctx.hover({ selector: PANEL });
};
const copied: Play = async (ctx) => {
  await open(ctx);
  // The panel's open motion moves the button under a pointer click aimed at its first position:
  // let it finish, then press the button itself, as `open` presses the toggle.
  const settled = () =>
    ctx.document
      .getAnimations()
      .every((animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity);
  await ctx.waitFor(settled);
  ctx.document.querySelector<HTMLButtonElement>(BUTTON)?.click();
  await ctx.waitFor(() => ctx.document.querySelector(`${BUTTON}[data-copied]`));
};

const variant = (look: CardCopyLook, card: Props["card"], state: "rest" | "hover" | "copied", note: string) => ({
  note,
  props: { look, card },
  play: state === "rest" ? open : state === "hover" ? hovered : copied,
});

const NOTES = {
  promptRest:
    "Selected look, at rest: the faint copy glyph in the prompt card's top-right corner; the first line wraps around it. Raw stays at the card's end.",
  promptHover:
    "The pointer on the card: the glyph goes full; only the glyph's own box lights when the pointer is on it, never the card.",
  promptCopied: "Clicked: the raw prompt is on the clipboard and the glyph is a check for a moment, then back to Copy.",
  messageRest: "Another agent's message, opened: the same corner copy, faint.",
  messageHover: "The message card hovered: the glyph at full.",
  messageCopied: "Clicked: the message's words are copied, a check shows.",
  quietRest: "Version B, at rest: a 12px glyph at 30%. Quieter, but hard to find on the glass.",
  quietCopied: "Version B, copied.",
  wordRest: "Version C, at rest: the default glyph.",
  wordCopied: 'Version C, copied: "Copied" beside the check. Wider, and it pushes the first line.',
};

export default componentEntry<Props>({
  id: "agent-pane.card-copy",
  title: "Card corner copy",
  area: "Agent pane",
  pane: true,
  height: 360,
  covers: [
    "agent-session/acpmux/conversation/CardCopy.tsx",
    "agent-session/acpmux/conversation/CopyButton.tsx",
    "agent-session/acpmux/conversation/SubsessionCallCard.tsx",
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
  ],
  load: async () => Stage,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    "prompt-rest": variant("faint", "prompt", "rest", NOTES.promptRest),
    "prompt-hover": variant("faint", "prompt", "hover", NOTES.promptHover),
    "prompt-copied": variant("faint", "prompt", "copied", NOTES.promptCopied),
    "message-rest": variant("faint", "message", "rest", NOTES.messageRest),
    "message-hover": variant("faint", "message", "hover", NOTES.messageHover),
    "message-copied": variant("faint", "message", "copied", NOTES.messageCopied),
    "quiet-rest": variant("quiet", "prompt", "rest", NOTES.quietRest),
    "quiet-copied": variant("quiet", "prompt", "copied", NOTES.quietCopied),
    "word-rest": variant("word", "prompt", "rest", NOTES.wordRest),
    "word-copied": variant("word", "prompt", "copied", NOTES.wordCopied),
  },
});
