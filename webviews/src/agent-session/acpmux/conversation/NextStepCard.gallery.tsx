// l10n-allow-file: gallery fixtures, not shipped UI.
// A tagged ask at the end of a turn (nextStepAsk.ts) as a card with its answers as buttons. Five
// looks: box (shipped, Claude desktop's next-step box: a bordered card, the first answer filled in
// the text colour with ⌘↩, as the question card's Submit), recap (the recap card's accent yes and
// bare text answers), inline (no card: the question and the buttons under the
// prose), consent (the consent card's buttons at the end of the row, ChatGPT's) and list (the
// answers stacked as rows, the question card's). Each look in its pending and answered states, with Yes and No, and with a list of answers.
import type React from "react";
import { componentEntry } from "../../../gallery/format";
import { nextStepAsk, chosenAnswer } from "./nextStepAsk";
import { NextStepCard } from "./NextStepCard";

type Look = "box" | "recap" | "inline" | "consent" | "list";
type Palette = "glass-dark" | "light-accent";
type Props = { look: Look; text: string; reply?: string; palette?: Palette };

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

function NextStepInPane({ look, text, reply, palette }: Props) {
  const ask = nextStepAsk(text)!;
  return (
    <div
      className="acpmux-shell acpmux-next-step-gallery"
      data-next-step-look={look}
      style={{
        flexDirection: "column",
        justifyContent: "flex-end",
        gap: 12,
        padding: 16,
        ...(palette ? PALETTES[palette] : {}),
      }}
    >
      <p style={{ margin: 0, color: "var(--agent-text)" }}>{ask.rest}</p>
      <NextStepCard
        ask={ask}
        answer={reply === undefined ? undefined : chosenAnswer(ask, reply)}
        onAnswer={() => Promise.resolve()}
        registerKey={() => () => undefined}
      />
    </div>
  );
}

const variant = (look: Look, text: string, reply: string | undefined, note: string, palette?: Palette) => ({
  note,
  props: { look, text, reply, palette },
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
