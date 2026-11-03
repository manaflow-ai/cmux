// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// Sent prompts in the transcript (PromptText.tsx PromptTyped, promptMarkdown.ts): plain text stays
// the literal text the person typed (a backslash, `~~x~~`, `$x$`, an indent, `#123`, `a<b`); only
// real Markdown (a list, a code span, bold, a table) goes through the renderer.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";

const plain = [
  user("grep for foo\\_bar, not foo_bar, and keep ~~old~~ in the name", 9),
  assistant("Searching for the escaped name.", 8),
  user("set $x$ to 5, then:\n    if a<b and #123 is open\n    cost stays $5 | $10", 6),
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
      note: "Plain prompts stay literal: the backslash in foo\\_bar stays, ~~old~~ is not struck through, $x$ is not math, and the indented lines keep their indent.",
      snapshot: chat(plain),
    },
    markdown: {
      note: "Prompts written in Markdown render: an ordered and a bullet list, a code span, bold, and a pipe table.",
      snapshot: chat(markdown),
    },
  },
});
