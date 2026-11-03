// l10n-allow-file: gallery fixtures (a sample reply ending in a ```ask fence), not shipped UI.
// An agent reply that ends in a multiple-choice ask (askFence.ts), drawn as a choice card (Leo,
// 2026-11-03, on Claude desktop's ask card: "for multiple choice things like that we can just render
// something pretty and usable"). A click sends the option as the next prompt; the card then reads as
// answered.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { Markdown } from "./Markdown";
import { TurnActionsContext, type TurnActions } from "./turnActions";

type Props = { canReply: boolean; options: "three" | "two" | "long" };

const OPTIONS: Record<Props["options"], string[]> = {
  three: ["Yes, add the hook", "Not now", "Fix CI"],
  two: ["Ship it", "Hold"],
  long: ["Publish the release notes to the blog now", "Publish tomorrow morning", "Keep them as a draft", "Skip"],
};

const reply = (options: string[]) =>
  [
    "The ultras session wasn't foregrounded by acpmux or cmux-next. It ran about 40 slow Bash calls in the foreground itself, and they stalled the turn.",
    "",
    "```ask",
    "Separately, the activity-row timer bug has been sent to the Thinking-timer helper.",
    "Add a hook that pushes known-slow commands to the background?",
    ...options.map((option) => `- ${option}`),
    "```",
    "",
  ].join("\n");

const sent: TurnActions = { reply: () => Promise.resolve(true) };

function Stage({ canReply, options }: Props) {
  return (
    <TurnActionsContext.Provider value={canReply ? sent : {}}>
      <div className="acpmux-shell" style={{ padding: 16, maxWidth: 640, flexDirection: "column" }}>
        <Markdown>{reply(OPTIONS[options])}</Markdown>
      </div>
    </TurnActionsContext.Provider>
  );
}

const answered: Play = async (ctx) => {
  await ctx.click({ selector: ".cv-ask-option[data-primary]" });
};

export default componentEntry<Props>({
  id: "agent-pane.ask-fence",
  title: "Reply ask: multiple-choice card",
  area: "Agent pane",
  pane: true,
  height: 360,
  covers: ["agent-session/acpmux/conversation/AskFenceCard.tsx", "agent-session/acpmux/conversation/askFence.ts"],
  load: async () => Stage,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    pending: {
      note: "Shipped: context muted, the question, the first option filled and the rest grey.",
      props: { canReply: true, options: "three" },
    },
    "two-options": { note: "A yes-or-no ask.", props: { canReply: true, options: "two" } },
    "long-options": { note: "Long options wrap onto a second row.", props: { canReply: true, options: "long" } },
    "read-only": {
      note: "A pane that cannot send (View Only): the buttons are disabled.",
      props: { canReply: false, options: "three" },
    },
    answered: {
      note: "After a click: the question with the chosen option under it in grey.",
      props: { canReply: true, options: "two" },
      play: answered,
    },
  },
});
