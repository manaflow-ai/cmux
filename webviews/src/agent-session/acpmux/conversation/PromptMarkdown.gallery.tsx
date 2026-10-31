// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// Sent prompts in the transcript (PromptText.tsx PromptTyped, promptMarkdown.ts): plain text stays
// the literal text the person typed, line breaks, `snake_case`, `__init__`, "$5 … $10" and "#123"
// included; only real Markdown (a list, a code span, a table) goes through the renderer.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";

const plain = [
  user("why does __init__ run twice when I import load_user_profile?", 9),
  assistant("It is imported under two module names, so Python runs it once for each.", 8),
  user("the plan costs between $5 and $10 a month, see #123\nkeep a<b and a | b as typed", 6),
  assistant("Noted: both stay as you wrote them.", 5),
];

const markdown = [
  user("do these, in order:\n1. rename user_id to account_id\n2. run `bun test`\n- then **ship** it", 9),
  assistant("On it.", 8),
  user("| flag | default |\n| --- | --- |\n| fast | on |", 6),
  assistant("Both flags are set.", 5),
];

export default agentPaneEntry({
  id: "agent-pane.prompt-markdown",
  title: "Sent prompts: Markdown only when written in Markdown",
  area: "Agent pane",
  height: 460,
  covers: [
    "agent-session/acpmux/conversation/PromptText.tsx#PromptTyped",
    "agent-session/acpmux/conversation/promptMarkdown.ts",
  ],
  variants: {
    plain: {
      note: "Plain prompts stay literal: __init__ is not bold, $5 … $10 is not math, #123 and a<b stay text, and the line break stays.",
      snapshot: chat(plain),
    },
    markdown: {
      note: "Prompts written in Markdown render: an ordered and a bullet list, a code span, bold, and a pipe table.",
      snapshot: chat(markdown),
    },
  },
});
