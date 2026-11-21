// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The prompt rail's right-click filter and its edges (Leo, 2026-11-07: "when you right-click the left
// scroll rail, you should be able to ... filter out the other agent messages to only your own, or
// filtering out your own to only the agent messages", and "if you scroll to the very top, there should
// be no fade. But then as you scroll down, like gradually, there's more and more of a fade"). Compare
// the rail's top edge at the very top, a few rows down and far down: none, part and a full fade; then
// the menu and the two filters.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";

const TOTAL = 60;
/// Sixty turns, every third prompt a message another agent sent in (its tick draws apart).
const rows: AcpmuxRow[] = Array.from({ length: TOTAL }, (_, index) => {
  const n = index + 1;
  const at = 300 - n * 2;
  const prompt =
    n % 3 === 0
      ? user(`Rollout lane: step ${n} is green`, at, {
          id: `user-${n}`,
          incoming: { kind: "message", message: { name: "Rollout lane", text: `Step ${n} is green`, raw: "" } },
        })
      : { ...user(`Prompt ${n}: inspect the next part of the rollout`, at), id: `user-${n}` };
  return [
    prompt,
    assistant(`Step ${n} checked.\n\nThe reply stays in the transcript.`, at + 0.2),
    summary(at + 0.4, { status: "completed" }),
  ];
}).flat();

/// The reader wheels the rail, then leaves it `offset` px from its top (railBrowsing keeps it there).
const railAt =
  (offset: number): Play =>
  async (ctx) => {
    const list = ctx.find({ selector: ".acpmux-minimap__list" });
    list.dispatchEvent(new ctx.document.defaultView!.WheelEvent("wheel", { deltaY: -1, bubbles: true }));
    await ctx.scroll({ selector: ".acpmux-minimap__list" }, offset);
  };
const filtered =
  (label: string): Play =>
  async (ctx) => {
    await ctx.contextMenu({ selector: ".acpmux-minimap__list" });
    await ctx.click({ role: "menuitemcheckbox", name: label });
  };

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-filter",
  title: "Thread minimap: filter by sender, edges that deepen",
  area: "Agent pane",
  height: 720,
  widths: { normal: 1040 },
  // The transcript holds still; the rail itself shortens when a filter drops ticks.
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  variants: {
    "top-no-fade": {
      note: "The rail scrolled to its very top: the first ticks draw in full ink, with no top fade.",
      snapshot: chat(rows, { title: "Rail: top" }),
      play: railAt(0),
    },
    "top-part-fade": {
      note: "Three rows down: the top edge fades a little, about a third of its full depth.",
      snapshot: chat(rows, { title: "Rail: part fade" }),
      play: railAt(30),
    },
    "top-full-fade": {
      note: "Far down: the full 2.5rem top fade.",
      snapshot: chat(rows, { title: "Rail: full fade" }),
      play: railAt(200),
    },
    menu: {
      note: "Right-click: Show All Messages (checked), Show Only My Messages, Show Only Agent Messages, then Move to Right Edge.",
      snapshot: chat(rows, { title: "Rail: menu" }),
      play: async (ctx) => ctx.contextMenu({ selector: ".acpmux-minimap__list" }),
    },
    mine: {
      note: "Show Only My Messages: the other agent's ticks leave the rail.",
      snapshot: chat(rows, { title: "Rail: mine" }),
      play: filtered("Show Only My Messages"),
    },
    agents: {
      note: "Show Only Agent Messages: only the other agent's ticks stay, each its own tick.",
      snapshot: chat(rows, { title: "Rail: agents" }),
      play: filtered("Show Only Agent Messages"),
    },
  },
});
