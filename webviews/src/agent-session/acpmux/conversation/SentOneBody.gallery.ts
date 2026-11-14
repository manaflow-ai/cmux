// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A sent message is one continuous text body (ask-14d16a6247; Leo, 2026-11-07, of his dictated
// message pasted in three parts and drawn as three "Pasted text" cards: "Like just don't separate
// these out. And, like, I thought we said, you know, remove these inner bubbles, inner, inner
// cards."). Each state draws a message as the transcript does: no card, no chevron and no gap of a
// paste's own, one Show more for the whole bubble. Compare the arms (`sent-paste-join`: as typed,
// blank line, line break) for where a paste meets the rest of the message.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow, PromptContentPart } from "../model";
import { sentPasteJoin } from "./sentPasteJoin.experiment";

/// Leo's message: one dictation that went in as three pastes, 1.6K, 503 and 218 characters.
const FIRST =
  "Okay, so the thing I keep noticing in the transcript is that when I send a message that I dictated, it comes back split into pieces. Like the first part is its own box, the second part is another box, and then there's a third one, and each of them has its own little arrow and its own Show more, with big gaps between them. That's not what I sent. I sent one message. I dictated it in a few goes because that's how dictation works, you pause, you think, you keep going, and the app pastes each bit as it finishes. But the bubble should read as one message, the same way it read in the composer before I hit send. Right now it reads like I attached three files. And I thought we already said to get rid of these inner cards inside the bubble. A bubble is the message. There's no reason for a card inside a card. If it's long, fold the whole thing once at the bottom, one Show more, and that's it. Don't fold each piece separately. That's the whole ask, really: just one body of text, the normal paragraph spacing, and one fold.";
const SECOND =
  "And the other thing is the composer side. When I paste something that's a few hundred words, it shouldn't turn into a Pasted text chip. That's just my words. Only make a chip when it's actually huge, like a whole log or a document, not a paragraph I dictated. Most of the time what I paste is what I'm saying, and it should stay as text I can see and edit right there in the prompt before I send it.";
const THIRD =
  "So yeah, one body in the bubble, no inner cards, one fold at the bottom, and keep pastes inline unless they're really big.";
const PARTS = [FIRST, SECOND, THIRD];

const reply = (rows: AcpmuxRow[]) =>
  chat([
    ...rows,
    assistant("Got it: one body, one fold, no inner cards.", 8.5),
    summary(8.5, { seq: 3, status: "completed" }),
  ]);

/// A transcript that recorded its pastes as ranges (the shape every older transcript has): the
/// pastes joined by acpmux's newline, each one's range.
function recorded(typed: string, pastes: string[]): AcpmuxRow {
  let text = typed;
  const pasted: { start: number; end: number }[] = [];
  for (const paste of pastes) {
    if (text) text += "\n";
    pasted.push({ start: text.length, end: text.length + paste.length });
    text += paste;
  }
  return user(text, 9, { seq: 1, pasted });
}

/// A message whose pastes the composer placed in its text (`inlineParts`): what was typed between
/// them is its own part, as the draft had it.
function placed(parts: PromptContentPart[]): AcpmuxRow {
  const text = parts.flatMap((part) => ("text" in part && part.text !== undefined ? [part.text] : [])).join("\n");
  return user(text, 9, { seq: 1, inlineParts: parts });
}
const paste = (text: string): PromptContentPart => ({ kind: "pasted", name: "Pasted text", text, placed: true });

const drawn = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-user__bubble"));
};

/// A screenshot's bytes in the row, as the pane's own send keeps them (inlinePrompt.ts keeps a
/// `data:` src): with no acpmux behind the gallery to read an image by its id, the thumbnail draws
/// from these.
const SHOT = `data:image/svg+xml,${encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" width="1440" height="900">' +
    '<rect width="100%" height="100%" fill="hsl(210 30% 16%)"/>' +
    '<rect width="100%" height="7%" fill="hsl(210 30% 26%)"/>' +
    '<rect width="22%" height="100%" fill="hsl(210 30% 24%)"/>' +
    '<rect x="26%" y="14%" width="60%" height="4%" rx="8" fill="hsl(210 30% 34%)"/>' +
    '<rect x="26%" y="22%" width="44%" height="4%" rx="8" fill="hsl(210 30% 30%)"/>' +
    "</svg>",
)}`;
const shotDrawn = async (ctx: PlayContext) => {
  await drawn(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".cv-user__bubble img"));
};

export default agentPaneEntry({
  id: "agent-pane.sent-one-body",
  title: "Sent message, one body",
  area: "Agent pane",
  height: 760,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: [
    "agent-session/acpmux/conversation/PromptText.tsx#PromptText",
    "agent-session/acpmux/conversation/InlinePromptContent.tsx#InlinePromptContent",
  ],
  keywords: ["paste", "pasted", "dictation", "inner card", "one body", "sent message", "fold"],
  variants: {
    "three-pastes-recorded": {
      note: "Leo's message as a transcript recorded it: three pasted ranges of 1.6K, 503 and 218 characters. One body, folded once at the bubble's twentieth line under one Show more; no card, chevron or gap per paste.",
      snapshot: reply([recorded("", PARTS)]),
      play: drawn,
    },
    "three-pastes-placed": {
      note: "The same three pastes placed in the draft with a space typed between them: the bubble reads as the composer did.",
      snapshot: reply([
        placed([paste(FIRST), { kind: "text", text: " " }, paste(SECOND), { kind: "text", text: " " }, paste(THIRD)]),
      ]),
      play: drawn,
    },
    "typed-then-pastes": {
      note: "A typed line, then two pastes: the typed words and the pastes are one body.",
      snapshot: reply([recorded("Two things from my notes:", [SECOND, THIRD])]),
      play: drawn,
    },
    "paste-and-image": {
      note: "A paste and a screenshot placed after it: the screenshot keeps its thumbnail; the paste is the message's text.",
      snapshot: reply([
        placed([
          paste(THIRD),
          {
            kind: "image",
            id: "gallery-shot",
            mimeType: "image/svg+xml",
            name: "image.png",
            width: 1440,
            height: 900,
            src: SHOT,
            placed: true,
          },
        ]),
      ]),
      play: shotDrawn,
    },
    "agent-paste": {
      note: "A pasted Codex handoff stands apart from the person's words under a quiet Pasted from Codex line, with no card.",
      snapshot: reply([
        recorded("Can you pick this up?", [
          "From Codex:\nHandoff: the upload probe is red on the second retry.\n\nTrace-ID: ask-77",
        ]),
      ]),
      play: drawn,
    },
  },
  experiment: {
    definition: sentPasteJoin,
    script: [{ name: "Draw the message", run: drawn }],
  },
});
