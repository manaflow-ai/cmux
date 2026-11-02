// l10n-allow-file: gallery fixtures (sample prompts and skill descriptions), not shipped UI.
// A skill's `/name` in a sent prompt (SkillWord.tsx): the composer's command blue, a dotted underline
// on hover and the skill's description as the app's tooltip above it. A Codex skill went as `/$name`
// and reads `/name` (slashCommands.ts withoutSkillDollars). A word that names no skill stays plain.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";

const commands = [
  { name: "init", description: "Create an AGENTS.md file with instructions for Codex", source: "agent" as const },
  {
    name: "$emil-design-vocabulary",
    description: "The precise design and UI vocabulary, for the exact word for a design idea",
    source: "skill" as const,
  },
  { name: "$emil-color", description: "", source: "skill" as const },
];

const rows = [
  user("hello lets use /$emil-design-vocabulary to figure out what the animations are", 9),
  assistant("Using the vocabulary skill to name each animation.", 8),
  user("then /$emil-color for the palette, and keep /init and /nope as text", 6),
  assistant("Done.", 5),
];

export default agentPaneEntry({
  id: "agent-pane.skill-words",
  title: "Sent prompts: skill words",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/conversation/SkillWord.tsx"],
  variants: {
    codex: {
      note: "Codex skills read /name in the command blue. /emil-design-vocabulary has a description: a dotted underline and its tooltip on hover. /emil-color has none: blue only. /init (a built-in) and /nope stay plain.",
      snapshot: chat(rows, { harness: "codex", commands }),
    },
  },
});
