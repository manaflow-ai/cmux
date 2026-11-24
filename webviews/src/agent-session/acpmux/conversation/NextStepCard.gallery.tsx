// l10n-allow-file: gallery fixtures, not shipped UI.
// A tagged ask at the end of a turn (nextStepAsk.ts) as a card with its answers as buttons. Five
// looks: box (shipped, Claude desktop's next-step box: a bordered card, the first answer filled in
// the text colour with ⌘↩, as the question card's Submit), recap (the recap card's accent yes and
// bare text answers), inline (no card: the question and the buttons under the
// prose), consent (the consent card's buttons at the end of the row, ChatGPT's) and list (the
// answers stacked as rows, the question card's). Each look in its pending and answered states, with Yes and No, and with a list of answers.
import React, { useLayoutEffect, useRef } from "react";
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { nextStepCardHeight } from "../permissions/cardHeight";
import type { AnswerBlock } from "../subagents/restart";
import { nextStepAsk, chosenAnswer, type NextStepAsk } from "./nextStepAsk";
import { NextStepCard } from "./NextStepCard";

type Look = "box" | "recap" | "inline" | "consent" | "list";
type Palette = "glass-dark" | "light-accent";
type Props = {
  look: Look;
  text: string;
  reply?: string;
  palette?: Palette;
  lines?: number | "none";
  /// A pane that cannot send: the card draws read only, with this reason.
  blocked?: AnswerBlock;
  /// An ask given whole (a wrap-up's recap), in place of one parsed from `text`.
  given?: NextStepAsk;
  superseded?: boolean;
};

// Themes the shipped box must stay readable in, set as the app's applyTheme would (theme.ts): a dark
// theme on a translucent window over a bright wallpaper, where --agent-page-bg is see-through glass
// (the case Leo hit: the filled Yes drew its label in the fill's white), and a light theme with a
// light accent. The wallpaper is a gradient stand-in.
const PALETTES: Record<Palette, React.CSSProperties> = {
  "glass-dark": {
    "--agent-text": "#f2f2f2",
    "--agent-muted": "rgba(242, 242, 242, 0.62)",
    "--agent-page-bg": "rgba(24, 24, 28, 0.18)",
    "--agent-accent-text": "#18181c",
    "--agent-accent": "#f2f2f2",
    colorScheme: "dark",
    background: "linear-gradient(135deg, #f7d6e6 0%, #fdf3f8 45%, #bfd9f2 100%)",
  } as React.CSSProperties,
  "light-accent": {
    "--agent-text": "#1d1d1f",
    "--agent-muted": "rgba(29, 29, 31, 0.6)",
    "--agent-page-bg": "rgba(255, 255, 255, 0.3)",
    "--agent-accent-text": "#ffffff",
    "--agent-accent": "#ffd7ec",
    colorScheme: "light",
    background: "linear-gradient(135deg, #fff1f8 0%, #ffffff 50%, #e8f2ff 100%)",
  } as React.CSSProperties,
};

const PROSE =
  "The slow session wasn't foregrounded by acpmux or cmux NEXT. It ran about 40 slow Bash calls in the foreground itself, and they stalled the turn.";

const YES_NO = `${PROSE}\n\n[outward] Should I add a hook that pushes known-slow commands to the background? It applies to every lane.`;
const CHOICES = `${PROSE}\n\n[taste] Which fix first?\n- Add the hook\n- Not now\n- Fix CI`;

// A coordinator's [irreversible] deploy ask much longer than a card's width (Leo, 2026-11-11: the ask
// was cut mid-word and could not be read): the whole of it wraps, and past the cap Show more opens the
// rest in place, the answers under it in their order.
const LONG = `${PROSE}\n\n[irreversible] Should I promote tonight's nightly to everyone now? It carries the session store migration, which rewrites every saved chat on first launch, keeps no copy of the old store once it finishes, and cannot be rolled back on a machine that has run it, so a bug in it would reach every chat everyone has, including the archived ones and the ones synced from another computer. The canary group ran it for six hours with no crash reports, but only twelve machines were in it, none of them with more than two thousand chats, so are you fine with promoting it before a bigger store has run it? The canary log and the migration's dry run on a copy of the biggest store we have are linked in the lane.`;

function NextStepInPane({ look, text, reply, palette, lines, blocked, given, superseded }: Props) {
  const ask = given ?? nextStepAsk(text)!;
  const answer = reply === undefined ? undefined : chosenAnswer(ask, reply);
  // The transcript's first height for this card at its drawn width (cardHeight.ts), beside the height
  // it draws, for next-step-card-gallery-browser.test.ts: the reply under it moves by their difference.
  const host = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const frame = host.current;
    const card = frame?.querySelector<HTMLElement>(".acpmux-next-step");
    if (!frame || !card) return;
    const measure = () => {
      const box = card.getBoundingClientRect();
      frame.dataset.estimate = String(nextStepCardHeight(ask, box.width, { answer, superseded }));
      frame.dataset.drawn = String(box.height);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(card);
    return () => observer.disconnect();
  });
  return (
    <div
      ref={host}
      className="acpmux-shell acpmux-next-step-gallery"
      data-next-step-look={look}
      style={{
        flexDirection: "column",
        justifyContent: "flex-end",
        gap: 12,
        padding: 16,
        ...(palette ? PALETTES[palette] : {}),
        ...(lines === undefined
          ? {}
          : ({ "--acpmux-next-step-lines": lines === "none" ? "none" : String(lines) } as React.CSSProperties)),
      }}
    >
      {ask.rest && <p style={{ margin: 0, color: "var(--agent-text)" }}>{ask.rest}</p>}
      <NextStepCard
        ask={ask}
        answer={answer}
        superseded={superseded}
        onAnswer={blocked ? undefined : () => Promise.resolve()}
        blocked={blocked}
        registerKey={blocked ? undefined : () => () => undefined}
      />
    </div>
  );
}

const variant = (look: Look, text: string, reply: string | undefined, note: string, palette?: Palette) => ({
  note,
  props: { look, text, reply, palette },
});

// A pane that cannot send (NextStepCard.tsx `blocked`): the same card read only, its reason last.
const blockedVariant = (blocked: AnswerBlock, note: string, text = CHOICES) => ({
  note,
  props: { look: "box" as Look, text, blocked },
});

const RECAP: NextStepAsk = {
  tag: "wrap_up",
  rest: "",
  recap:
    "Moved the composer settings into one page, removed the duplicate toggle in Advanced, and kept every setting's key so old configs still load.",
  question: "Ship it?",
  options: [
    { label: "Yes", key: "recap.yes" },
    { label: "Not now", key: "recap.notNow" },
  ],
};
const WRAPPING = `${PROSE}\n\n[taste] Which fix should go in first?\n- The estimate, so the reply under the card stops jumping when it renders\n- The copy`;
const given = (ask: NextStepAsk, note: string, extra: Partial<Props> = {}) => ({
  note,
  props: { look: "box" as Look, text: "", given: ask, ...extra },
});

const long = (note: string, lines?: number | "none", open = false) => ({
  note,
  height: 560,
  props: { look: "box" as Look, text: LONG, lines },
  ...(open
    ? {
        play: async (ctx: PlayContext) => {
          await ctx.click({ selector: ".acpmux-next-step__more" });
          await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-next-step__text[data-whole]")));
        },
      }
    : {}),
});

export default componentEntry({
  id: "agent-pane.next-step-card",
  title: "Agent pane: tagged ask as answer buttons",
  area: "Agent pane",
  pane: true,
  height: 280,
  widths: { narrow: 420, normal: 640, wide: 820 },
  anchors: [{ selector: ".acpmux-next-step" }],
  covers: ["agent-session/acpmux/conversation/NextStepCard.tsx#NextStepCard"],
  styles: () => Promise.all([import("../styles.css"), import("./NextStepCard.gallery.css")]),
  load: async () => NextStepInPane,
  variants: {
    "box-choices": variant(
      "box",
      CHOICES,
      undefined,
      "Shipped: Claude desktop's box, three answers, the first filled with ⌘↩.",
    ),
    "box-yes-no": variant(
      "box",
      YES_NO,
      undefined,
      "Shipped: a yes-or-no ask gets Yes and No; its tail is the muted line.",
    ),
    "box-yes-no-glass-dark": variant(
      "box",
      YES_NO,
      undefined,
      "Shipped, dark theme on a translucent window over a bright wallpaper: Yes reads dark on its light fill.",
      "glass-dark",
    ),
    "box-yes-no-light-accent": variant(
      "box",
      YES_NO,
      undefined,
      "Shipped, light theme with a light accent: Yes reads light on its dark fill.",
      "light-accent",
    ),
    "box-answered": variant("box", CHOICES, "Add the hook", "Shipped: answered, the question and the answer in grey."),
    "box-answered-typed": variant(
      "box",
      YES_NO,
      "Only for lanes, not coordinators",
      "Shipped: a typed reply reads as the answer.",
    ),
    "box-long": long(
      "Shipped: a very long ask shows its first eight lines, wrapped at word breaks, with Show more under them; the answers stay under it.",
    ),
    "box-long-open": long(
      "Shipped, Show more opened: the whole ask in place, Show less under it, the answers in the same order under that.",
      undefined,
      true,
    ),
    "box-long-four-lines": long("Alternative: a four-line cap, the hat's density, more clicks to read an ask.", 4),
    "box-long-whole": long(
      "Alternative: no cap, the whole ask always, as Claude's question card; a long ask pushes its answers far down.",
      "none",
    ),
    "box-watching": blockedVariant("watching", "View Only: the same card read only; its last row says to take over."),
    "box-subagent": blockedVariant("subagent", "A subagent's own pane: read only; answer in the main chat."),
    "box-disconnected": blockedVariant("disconnected", "Not connected: read only."),
    "box-remote": blockedVariant("remote", "A remote Codex or opencode chat this Mac cannot send to: read only."),
    "box-origin": blockedVariant("origin", "A connection from an older cmux: read only; update cmux to answer here."),
    "box-guest": blockedVariant("guest", "A shared chat's guest: read only; only the owner answers."),
    "box-wrapping": variant("box", WRAPPING, undefined, "An answer label that wraps adds a line to its row."),
    "box-wrapping-watching": blockedVariant("watching", "The wrapped label, read only: the same height.", WRAPPING),
    "box-long-watching": {
      ...long("A very long ask, read only: the same height, Show more included."),
      props: { look: "box" as Look, text: LONG, blocked: "watching" as AnswerBlock },
    },
    "wrap-up-recap": given(RECAP, "A wrap-up's recap muted over the question."),
    "wrap-up-recap-watching": given(RECAP, "The wrap-up, read only.", { blocked: "watching" }),
    "wrap-up-recap-answered": given(RECAP, "The wrap-up answered: the recap over the question and the answer.", {
      reply: "Yes",
    }),
    "wrap-up-recap-only": given(
      {
        tag: "wrap_up",
        rest: "",
        recap: "Moved the composer settings into one page. Nothing needs you.",
        question: "",
        options: [],
      },
      "A recap with nothing to decide: the recap box alone.",
    ),
    "box-superseded": {
      note: "A later card took over: the question alone, folded.",
      props: { look: "box" as Look, text: CHOICES, superseded: true },
    },
    "box-no-answers": given(
      { tag: "taste", rest: "", question: "Anything else before I start?", options: [] },
      "A question with no answers: no rows and no last row.",
    ),
    "box-no-answers-watching": given(
      { tag: "taste", rest: "", question: "Anything else before I start?", options: [] },
      "The same, read only.",
      { blocked: "watching" },
    ),
    "recap-choices": variant(
      "recap",
      CHOICES,
      undefined,
      "Alternative: the recap card's accent yes, the rest bare text.",
    ),
    "inline-choices": variant("inline", CHOICES, undefined, "Alternative: no card, buttons under the prose."),
    "inline-answered": variant("inline", CHOICES, "Add the hook", "Alternative: answered."),
    "consent-choices": variant("consent", CHOICES, undefined, "Alternative: the consent card, buttons right-aligned."),
    "consent-yes-no": variant("consent", YES_NO, undefined, "Alternative: the consent card, yes or no."),
    "list-choices": variant("list", CHOICES, undefined, "Alternative: answers stacked as rows, the question card's."),
  },
});
