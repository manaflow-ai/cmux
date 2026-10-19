// l10n-allow-file: gallery fixtures (sample thoughts), not shipped UI.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { ThoughtFold } from "./ThoughtFold";

const text =
  "**Checking the retry path**\n\nThe upload uses a single request. I will check its failure path before adding retries.";

export default componentEntry<ComponentProps<typeof ThoughtFold>>({
  id: "agent-pane.thought-fold",
  title: "Thought fold",
  area: "Agent pane",
  pane: true,
  height: 260,
  covers: [
    "agent-session/acpmux/conversation/ThoughtFold.tsx#ThoughtFold",
    "agent-session/acpmux/conversation/icons.tsx#Brain",
  ],
  load: () => import("./ThoughtFold").then((module) => module.ThoughtFold),
  variants: {
    closed: { props: { text } },
    streaming: { props: { text, streaming: true } },
    open: {
      props: { text },
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-thought-fold" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-thought-fold__body"));
      },
    },
  },
});
