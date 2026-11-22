// l10n-allow-file: gallery composition, not shipped UI.
// The chat and the subagent it opened in the right split, side by side as the app lays them out:
// the two variants of subagentSplit.gallery.ts, each a live agent pane in its own frame. References:
// codex/web/sidebar-parallel-agents, codex/web/multitask, codex-mobile/live/agents-sheet-active-completed
// and codex-mobile/live/grouped-activity-rows (cmux-design-references), and Leo's ChatGPT task thread
// (2026-11-02): the parent on the left with the task's chip, the task's own thread on the right.
import { createElement } from "react";
import { readEnv, frameQuery } from "../../../gallery/env";
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { SPLIT_ENTRY } from "./subagentSplit.gallery";

type Props = { gap: number };

/// A pane's stage: this gallery's frame with the outer stage's settings (theme, locale, font).
const stage = (variant: string) => {
  const here = new URL(typeof location !== "undefined" ? location.href : "http://localhost:5173/gallery/frame.html");
  const base = here.pathname.replace(/[^/]*$/, "");
  return `${base}frame.html?${frameQuery({ entry: SPLIT_ENTRY, variant }, readEnv(here.searchParams))}`;
};

function SplitPair({ gap }: Props) {
  const frame = (variant: string) =>
    createElement("iframe", {
      key: variant,
      title: variant,
      "data-pane": variant,
      src: stage(variant),
      style: { flex: "1 1 0", minWidth: 0, height: "100%", border: 0 },
    });
  return createElement(
    "div",
    { style: { display: "flex", gap, width: "100%", height: 640 } },
    frame("parent"),
    frame("child"),
  );
}

/// Each pane's frame once its own play ran: ready, and its document.
async function pane(ctx: PlayContext, variant: string): Promise<Document> {
  const inner = () =>
    ctx.document.querySelector<HTMLIFrameElement>(`iframe[data-pane="${variant}"]`)?.contentDocument ?? undefined;
  // Ends on "error" too, so a pane that failed to load fails here at once, not at the cap.
  const state = () => inner()?.documentElement.dataset.galleryReady;
  await ctx.waitFor(() => state() === "1" || state() === "error", { capMs: 20_000 });
  if (state() === "error") throw new Error(`the ${variant} pane failed to load`);
  const doc = inner()!;
  if (doc.documentElement.dataset.galleryPlay === "fail") throw new Error(`the ${variant} pane's play failed`);
  return doc;
}

export default componentEntry<Props>({
  id: "agent-pane.subagent-split-pair",
  title: "Chat and its subagent side by side",
  area: "Agent pane",
  height: 660,
  covers: ["agent-session/acpmux/subagents/SubagentGroup.tsx#SubagentOfRow"],
  keywords: ["subagent", "split", "side by side", "task thread"],
  load: async () => SplitPair,
  variants: {
    default: {
      note: "Left: the chat, its subagents' states, Session Info open. Right: the subagent the person opened, titled by its task, its transcript, Session Info closed.",
      props: { gap: 1 },
      play: async (ctx) => {
        const left = await pane(ctx, "parent");
        const right = await pane(ctx, "child");
        if (!left.querySelector(".acpmux-session-info[data-presence='shown']"))
          throw new Error("the parent's Session Info is not open");
        if (!left.querySelector(".acpmux-running-tray") || !left.querySelector(".cv-subagent-done"))
          throw new Error("the parent shows no subagent states");
        if (!right.querySelector(".cv-subagent-of__task")) throw new Error("the child pane has no title");
        if (right.querySelector(".acpmux-session-info[data-presence='shown']"))
          throw new Error("the child pane inherited Session Info open");
      },
    },
  },
});
