// l10n-allow-file: gallery fixture text is deterministic sample context, not shipped copy.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { ContextViewer, type ContextPart } from "./ContextViewer";

const parts: ContextPart[] = [
  {
    id: "harness-base",
    label: "Harness base prompt",
    source: "Claude Code",
    scope: "builtin",
    text: "You are an agent. Read relevant files early and use parallel tool calls when independent.",
    tokenCount: 18,
  },
  {
    id: "cmux-guidance",
    label: "cmux guidance",
    source: "cmux NEXT",
    scope: "user",
    text: "Keep work moving concurrently. Report the result and the evidence.",
    tokenCount: 13,
    editable: true,
  },
  {
    id: "skills",
    label: "Skills listing",
    source: "acpmux",
    scope: "project",
    text: "openai-docs · imagegen · skill-creator",
    tokenCount: 9,
  },
  {
    id: "mcp",
    label: "MCP server instructions",
    source: "repo MCP",
    scope: "session",
    text: "Read repository state from the shared mirror before making edits.",
    tokenCount: 12,
  },
];

type Props = ComponentProps<typeof ContextViewer>;

const baseline: Props = {
  parts,
  harness: "Claude Code",
  sessionId: "gallery-context-claude",
  onSaveOverride: () => undefined,
  onResetOverride: () => undefined,
};

const editPlay: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /cmux guidance/ });
  const editor = ctx.document.querySelector<HTMLTextAreaElement>('[data-part-id="cmux-guidance"] textarea');
  if (!editor) throw new Error("editable cmux guidance part did not open");
  editor.value = "Prefer concurrent reads and concise reports.";
  editor.dispatchEvent(new Event("input", { bubbles: true }));
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Save" }).getAttribute("disabled") === null);
};

export default componentEntry<Props>({
  id: "agent-pane.context-viewer",
  title: "Context viewer",
  area: "Agent pane",
  pane: true,
  height: 760,
  widths: { narrow: 440, normal: 640, wide: 860 },
  anchors: [{ selector: ".acpmux-context-viewer" }],
  covers: ["agent-session/acpmux/ContextViewer.tsx#ContextViewer"],
  styles: () => import("./contextViewer.css"),
  load: async () => ContextViewer,
  variants: {
    baseline: { note: "Exact effective context grouped by source with compact token metadata.", props: baseline },
    "edit-cmux-guidance": { note: "An editable cmux-added part saved at user or project scope.", props: baseline, play: editPlay },
    empty: { note: "A session that has not emitted context yet.", props: { ...baseline, parts: [] } },
    loading: { note: "The context request is in flight.", props: { ...baseline, loading: true } },
  },
});

