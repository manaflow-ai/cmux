// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { SessionMarkHillClimb, type SessionMarkHillClimbProps } from "./SessionMarkHillClimbGallery";

const note = (scheme: string) =>
  `Open (Leo, 2026-11-22: "why diamonds? ... go hill climb this"): today's sparkle, the harness mark, the mark with a branch badge, and the mark with a hook under its parent, beside thinking and tool rows, ${scheme}.`;

export default componentEntry<SessionMarkHillClimbProps>({
  id: "agent-pane.session-mark-hillclimb",
  title: "Session and subagent marks: sparkle or harness",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { normal: 900, wide: 1100 },
  covers: ["agent-session/acpmux/subagents/SessionMarkHillClimbGallery.tsx"],
  load: async () => SessionMarkHillClimb,
  styles: () =>
    Promise.all([import("../../../ui/ui.css"), import("./subagents.css"), import("./sessionMarkHillClimb.css")]),
  keywords: ["sparkle", "diamond", "subagent", "session", "harness", "claude", "codex", "mark", "badge"],
  variants: {
    light: { props: { scheme: "light" }, note: note("light") },
    dark: { props: { scheme: "dark" }, note: note("dark") },
    paper: { props: { scheme: "paper" }, note: note("on a warm paper fill") },
    midnight: { props: { scheme: "midnight" }, note: note("on a midnight fill") },
  },
});
