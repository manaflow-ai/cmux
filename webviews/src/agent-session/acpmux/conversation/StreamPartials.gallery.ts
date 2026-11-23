// l10n-allow-file: gallery fixtures (sample replies cut mid-stream), not shipped UI.
// AUDIT (uncommitted): partial replies streaming in the real pane, under their prompt, in the
// transcript's column: the streaming reply's tail as the person sees it.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";

const ASK = "How long do the checks take?";
const live = (text: string) =>
  chat([user(ASK, 1), assistant(text, 0.9, { streaming: true })], { title: "Checks", isWorking: true });

const TABLE_HEAD = "Here are the runs:\n\n| Check | Base |\n| --- | --- |\n| lint | 41 s |\n| bun test | 2 m 10 s |\n";
const WIDE_ROW = "| the browser lane, which runs separately on its own runner | 3 m 02 s |\n";

export default agentPaneEntry({
  id: "agent-pane.stream-partials",
  title: "AUDIT: partial replies streaming in the pane",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/conversation/RevealedMarkdown.tsx"],
  variants: {
    "table-short-rows": { snapshot: live(TABLE_HEAD) },
    "table-wide-row": { snapshot: live(`${TABLE_HEAD}${WIDE_ROW}`) },
    "table-finished": {
      snapshot: chat([user(ASK, 1), assistant(`${TABLE_HEAD}${WIDE_ROW}\nAfter the table.`, 0.9)], { title: "Checks" }),
    },
    "code-open": {
      snapshot: live("Run this:\n\n```typescript\nexport const retry = 3;\nexport const backoffMs = 250;"),
    },
    "diagram-open": {
      snapshot: live("The flow:\n\n```mermaid\ngraph TD\n  A[Prompt] --> B[Agent]\n  B --> C[Tools]\n"),
    },
    "chart-open": {
      snapshot: live(
        'Times:\n\n```vega-lite\n{"$schema": "https://vega.github.io/schema/vega-lite/v5.json",\n "width": 300, "height": 160,\n',
      ),
    },
    "chart-finished": {
      snapshot: chat(
        [
          user(ASK, 1),
          assistant(
            'Times:\n\n```vega-lite\n{"$schema": "https://vega.github.io/schema/vega-lite/v5.json", "width": 300, "height": 160, "data": {"values": [{"k": "lint", "s": 41}, {"k": "test", "s": 130}]}, "mark": "bar", "encoding": {"x": {"field": "k", "type": "nominal"}, "y": {"field": "s", "type": "quantitative"}}}\n```\n\n| Check | Base |\n| --- | --- |\n| lint | 41 s |\n\nDone.',
            0.9,
          ),
        ],
        { title: "Checks" },
      ),
    },
    "math-open": { snapshot: live("The energy is $E=mc^2$ for a body at rest.\n\n$$\n\\int_0^1 x\\,dx") },
    "list-growing": { snapshot: live("Steps:\n\n- first item\n- second item\n  - nested under the sec") },
  },
});
