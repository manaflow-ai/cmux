// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The composer hat's top bar (SubagentTray.tsx header, HatHeadDeck.tsx, hatHeader.css). Lawrence,
/// 2026-11-20: "ui for opening subagents is very confusing". Leo: "we need to be able to like thumb
/// through them like a Rolodex or whatever at the top ... you hover over it, and then on each one, it's
/// like there's a slight pop ... perhaps the text itself maybe changes like on the top of the composer
/// hat ... you can click into them and be able to open up that sub-agent", and on the hide control:
/// "where would the hide button be? Would it be good at the left? ... Would like an entire small slight
/// sort of bar make sense? ... Versus just having this unobtrusive little icon". The `strip` and
/// `cards` arms are two ways to thumb through what runs; `eye`, `pill` and `bar` keep the strip and try
/// three places for the hide control. cmux #47923 (`composer-hat-rolodex`) makes today's stacked
/// marks a Rolodex; these arms try a mark per running line and a card deck beside it. Compare them
/// in the gallery's `agent-pane.composer-hat-header`.
export const hatHeaderLook = defineExperiment({
  id: "composer-hat-header",
  title: "Composer hat: the top bar",
  description:
    "The hat's top bar: as today, one harness icon per running line that pops and names its line on hover (a click opens it), a deck of cards that flips to the hovered one, or the icon strip with the hide control as an eye circle at the right, a pill at the left, or a slim bar along the top.",
  arms: {
    today: {
      label: "Today",
      description:
        "The header's stacked marks, the counts or the leading names, its time and chevron; the tuck tab hangs from the hat's top edge.",
    },
    strip: {
      label: "Icon strip",
      description:
        "One harness icon per running line (Claude, Codex, a command's terminal). Pointing at one pops it and the header's words become that line's name and latest step; running the pointer along the strip thumbs through them with no delay; a click opens it; leaving gives the summary back.",
    },
    cards: {
      label: "Rolodex cards",
      description:
        "The running lines as a fanned deck of small cards. The hovered card flips to the front and names its line in the header; the scroll wheel over the deck thumbs card to card; a click opens the front card.",
    },
    eye: {
      label: "Strip, eye at the right",
      description:
        "The icon strip, and the hide control as a small eye-slash circle flush in the bar's trailing controls, always shown in muted ink, before the chevron.",
    },
    pill: {
      label: "Strip, pill at the left",
      description:
        "The icon strip, and the hide control as a small glass pill leading the bar on the left, attached to the hat's edge.",
    },
    bar: {
      label: "Strip, slim bar on top",
      description:
        "The icon strip, and a slim full-width bar along the hat's top: a press hides the hat, a drag resizes it; its eye-slash shows on hover.",
    },
  },
  defaultArm: "today",
});

export type HatHeaderArm = keyof typeof hatHeaderLook.arms;

/// The deck the arm draws in the header, if any.
export function deckOf(arm: HatHeaderArm): "strip" | "cards" | undefined {
  if (arm === "today") return undefined;
  return arm === "cards" ? "cards" : "strip";
}

/// Where the arm puts the hide control, if it moves it from today's top-edge tab.
export function hideOf(arm: HatHeaderArm): "eye" | "pill" | "bar" | undefined {
  return arm === "eye" || arm === "pill" || arm === "bar" ? arm : undefined;
}
