// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
import { useLayoutEffect } from "react";
import { componentEntry } from "../../../gallery/format";

type Props = { text: string; collapse: boolean; times: boolean };
const long = Array.from({ length: 16 }, (_, index) => `Step ${index + 1}: check the retry policy.`).join("\n");

export default componentEntry<Props>({
  id: "agent-pane.prompt-labs",
  title: "Prompt labs",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 500,
  covers: ["agent-session/acpmux/conversation/PromptBubble.tsx", "agent-session/acpmux/conversation/MessageTime.tsx"],
  load: async () => {
    const { PromptBubble } = await import("./PromptBubble");
    const { configureLabs } = await import("../labs");
    return function PromptLabsGallery(props: Props) {
      useLayoutEffect(() => {
        configureLabs({ labs: { promptCollapse: props.collapse, messageTimes: props.times } });
        return () => configureLabs(undefined);
      }, [props.collapse, props.times]);
      return (
        <div className="cv-user">
          <PromptBubble row={{ id: "gallery", at: 1_580_639_660_000, kind: "user", version: 1 }} {...props} />
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    short: { props: { text: "Cover the retry policy with a focused test.", collapse: true, times: false } },
    collapsed: { props: { text: long, collapse: true, times: false } },
    expanded: {
      props: { text: long, collapse: true, times: false },
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-user__expand" });
      },
    },
    "sent-time": {
      note: "Focus the bubble to show the prompt's own date and time.",
      props: { text: "When did I send this?", collapse: false, times: true },
      play: async (ctx) => {
        await ctx.press("Tab");
      },
    },
  },
});
