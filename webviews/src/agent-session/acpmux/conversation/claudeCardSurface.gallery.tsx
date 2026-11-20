// l10n-allow-file: synthetic gallery fixtures and developer experiment descriptions.
import { componentEntry } from "../../../gallery/format";
import { activity, summary, tool } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { claudeCardSurface } from "./claudeCardSurface.experiment";

type Props = { state: "tool" | "edited" | "error" };
const edited = activity(
  [
    tool("Edit src/demo.ts", "edit", "completed", {
      diffs: [{ path: "src/demo.ts", oldText: "export const count = 1;\n", newText: "export const count = 2;\n" }],
    }),
    tool("Edit src/title.ts", "edit", "completed", {
      diffs: [
        {
          path: "src/title.ts",
          oldText: 'export const title = "Demo";\n',
          newText: 'export const title = "Card demo";\n',
        },
      ],
    }),
  ],
  2,
);
const failed = summary(1, { status: "failed", error: "agent process closed", toolCount: 1 });
const open: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector("button.cv-tool, .acpmux-edited, .cv-turn-error"));
  if (ctx.document.querySelector("button.cv-tool")) {
    if (!ctx.document.querySelector(".cv-tool-output-card")) await ctx.click({ selector: "button.cv-tool" });
    await ctx.waitFor(() => ctx.document.querySelector(".cv-tool-output-card"));
  } else if (ctx.document.querySelector(".cv-turn-error__details")) {
    if (!ctx.document.querySelector(".cv-turn-error__details[open]"))
      await ctx.click({ selector: ".cv-turn-error__details summary" });
    await ctx.waitFor(() => ctx.document.querySelector(".cv-turn-error__details[open]"));
  }
};

export default componentEntry<Props>({
  id: "agent-pane.claude-card-surface",
  title: "Claude look card surfaces",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/conversation/ToolOutputBody.tsx#ToolOutput",
    "agent-session/acpmux/conversation/EditedFilesCard.tsx#EditedFilesCard",
    "agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter",
  ],
  load: async () => {
    const [{ ToolRow }, { EditedFilesCard }, { TurnFooter }] = await Promise.all([
      import("./ToolRow"),
      import("./EditedFilesCard"),
      import("./TurnRows"),
    ]);
    return function Cards({ state }: Props) {
      return (
        <div style={{ padding: 16 }}>
          {state === "tool" ? (
            <ToolRow
              item={{
                kind: "tool",
                text: "Read demo result",
                tool: {
                  id: "claude-card-demo",
                  title: "Read demo result",
                  kind: "fetch",
                  status: "completed",
                  output:
                    "## Demo result\n\nThe card keeps **all** of its content.\n\n```ts\nexport const count = 2;\n```\n\n[Documentation](https://example.test/docs)",
                },
              }}
            />
          ) : state === "edited" ? (
            <EditedFilesCard row={edited} />
          ) : (
            <TurnFooter row={failed} />
          )}
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("../chips/chips.css")]),
  widths: { narrow: 420, normal: 720, wide: 960 },
  height: 460,
  experiment: {
    definition: claudeCardSurface,
    script: [{ name: "Open the tool output or error details", run: open }],
  },
  variants: {
    "tool-output": {
      props: { state: "tool" },
      play: open,
      note: "Opened tool output; compare compact and soft in light and dark themes.",
    },
    "edited-files": {
      props: { state: "edited" },
      note: "Two synthetic edits; the card keeps its original rows, dimensions and controls.",
    },
    "turn-error": {
      props: { state: "error" },
      play: open,
      note: "A failed turn with its own error text disclosed; recovery controls stay unchanged.",
    },
  },
});
