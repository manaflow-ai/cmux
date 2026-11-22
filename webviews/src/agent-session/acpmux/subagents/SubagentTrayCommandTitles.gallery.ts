// l10n-allow-file: gallery fixtures (commands, descriptions), not shipped UI.
// The running tray's background command lines (SubagentTray.tsx, session-info/commandRules.ts
// `commandRead`). Leo, 2026-11-04, on an open tray of lines reading "Command hold", "Command review
// result": "wtf are these holds". They were a subagent's Claude Monitor calls, which an agent names
// in a word or two; acpmux did not know the Monitor call, so the line had only that word. Now a
// word-or-two description follows what the command does ("Waiting 14m · hold"), the raw command
// appears as its dim monospace activity, and a subagent's line says whose it is.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { CommandTitlesScene } from "../../../gallery/fixtures/SubagentTrayCommandTitlesStage";

const open = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
  const head = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
  if (head?.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray li"));
};

export default componentEntry<{ scene: CommandTitlesScene }>({
  id: "agent-pane.subagent-tray-command-titles",
  title: "Running tray command lines name what runs",
  area: "Agent pane",
  covers: ["agent-session/acpmux/subagents/SubagentTray.tsx", "agent-session/acpmux/session-info/commandRules.ts"],
  load: () =>
    import("../../../gallery/fixtures/SubagentTrayCommandTitlesStage").then(
      (module) => module.SubagentTrayCommandTitlesStage,
    ),
  pane: true,
  height: 340,
  variants: {
    terse: {
      note: "Leo's tray: descriptions of a word or two ('hold', 'review result') follow what the command does: 'Waiting 14m · hold', 'Waiting for b0luhqojj.output · review result'.",
      props: { scene: "terse" },
      play: open,
    },
    long: {
      note: "A long description is the line as it is ('Check PR #3119 for a HOLD line before landing it'); the row's ellipsis cuts it at the end, never to a word.",
      props: { scene: "long" },
      play: open,
    },
    none: {
      note: "No description (Codex): the command reads from its program: 'Waiting 14m', 'Waiting for …output', 'npm run lint'.",
      props: { scene: "none" },
      play: open,
    },
    subagent: {
      note: "A subagent's commands name it first: 'Reviewer · Waiting 14m · hold'; the chat's own command has no owner.",
      props: { scene: "subagent" },
      play: open,
    },
  },
});
