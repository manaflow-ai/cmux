// l10n-allow-file: gallery fixtures carry part labels and prompt text as acpmux reports them.
import { useCallback, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { ContextScreen, type ContextLayout, type ContextOverride } from "./ContextScreen";

const GUIDANCE =
  "Read relevant instructions and likely source files early. Batch independent reads and searches into parallel tool calls; sequence dependent work.";

/// An inventory as `_acpmux/context` answers for a Claude Code chat that reported its /context.
const inventory = (overrides: { user?: string; project?: string } = {}, canEditOverrides = true) => ({
  parts: [
    {
      id: "harness-category-0-system",
      source: "harness",
      label: "System prompt",
      tokens: 3100,
      included: true,
      editable: false,
      measurement: "measured",
    },
    {
      id: "harness-category-1-tools",
      source: "harness",
      label: "System tools",
      tokens: 14800,
      included: true,
      editable: false,
      measurement: "measured",
    },
    {
      id: "harness-category-2-messages",
      source: "harness",
      label: "Messages",
      tokens: 42200,
      included: true,
      editable: false,
      measurement: "measured",
    },
    {
      id: "memory-0",
      source: "memory",
      label: "~/.claude/CLAUDE.md",
      tokens: 2400,
      included: true,
      editable: false,
      measurement: "measured",
    },
    {
      id: "mcp-tool-0",
      source: "mcp",
      label: "mcp__cmux__cmux_exec",
      tokens: 1900,
      included: true,
      editable: false,
      measurement: "measured",
    },
    {
      id: "skill-0",
      source: "skill",
      label: "cmux:cmux-chat",
      tokens: 120,
      included: true,
      editable: false,
      measurement: "measured",
    },
    {
      id:
        overrides.project !== undefined
          ? "cmux-project-override"
          : overrides.user !== undefined
            ? "cmux-user-override"
            : "cmux-default-override",
      source:
        overrides.project !== undefined ? "cmux-project" : overrides.user !== undefined ? "cmux-user" : "cmux-default",
      label: "cmux guidance (system prompt)",
      tokens: 40,
      included: true,
      editable: true,
      measurement: "estimated",
      channel: "append-system-prompt",
      ...(canEditOverrides ? { text: overrides.project ?? overrides.user ?? GUIDANCE } : {}),
    },
    {
      id: "cmux-guidance",
      source: "cmux-guidance",
      label: "cmux chat guidance and your skills (system prompt)",
      tokens: 90,
      included: true,
      editable: false,
      measurement: "estimated",
      channel: "append-system-prompt",
      ...(canEditOverrides
        ? { text: "This chat runs in cmux NEXT, which draws your TodoWrite list as a checklist." }
        : {}),
    },
    {
      id: "cmux-source-mcp-base",
      source: "cmux-mcp-instructions",
      label: "cmux MCP instructions (code mode)",
      tokens: 410,
      included: true,
      editable: false,
      measurement: "estimated",
      channel: "mcp-instructions",
      ...(canEditOverrides
        ? { text: "This chat runs in cmux: a terminal, tab or workspace the person asks for is a cmux one." }
        : {}),
    },
    {
      id: "cmux-source-mcp-server-github",
      source: "cmux-mcp-catalog",
      label: "MCP server: github (folded into cmux)",
      tokens: 0,
      included: false,
      editable: false,
      measurement: "unavailable",
      channel: "mcp-tools",
    },
  ],
  totalTokens: 64600,
  providerTotalTokens: 64600,
  cmuxTokens: 540,
  maxTokens: 200000,
  canEditOverrides,
  overrides: {
    defaultText: canEditOverrides ? GUIDANCE : undefined,
    user: canEditOverrides ? (overrides.user ?? null) : null,
    project: canEditOverrides ? (overrides.project ?? null) : null,
    projectKey: "demo",
    cwd: "/Users/demo/project",
  },
});

type Props = {
  layout: ContextLayout;
  saved?: { user?: string; project?: string };
  remote?: boolean;
  fails?: boolean;
  pending?: boolean;
};

function GalleryContext({ layout, saved = {}, remote = false, fails = false, pending = false }: Props) {
  const [state, setState] = useState(saved);
  const [closed, setClosed] = useState(false);
  const load = useCallback(
    () =>
      pending
        ? new Promise<unknown>(() => undefined)
        : fails
          ? Promise.reject(new Error("acpmux is not running"))
          : Promise.resolve(inventory(state, !remote)),
    [pending, fails, remote, state],
  );
  const save = (change: ContextOverride) => {
    const next = { ...state, [change.scope]: change.text ?? undefined };
    setState(next);
    return Promise.resolve(inventory(next));
  };
  if (closed) return <output data-context-closed="">Closed</output>;
  return (
    <div style={{ display: "flex", height: "100%" }}>
      <ContextScreen load={load} {...(remote ? {} : { save })} onClose={() => setClosed(true)} layout={layout} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.context-screen",
  title: "Context screen",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 360, normal: 640, wide: 960 },
  covers: [
    "agent-session/acpmux/context/ContextScreen.tsx#ContextScreen",
    "agent-session/acpmux/context/contextInventory.ts#parseInventory",
  ],
  styles: () => import("../styles.css"),
  load: async () => GalleryContext,
  variants: {
    list: {
      note: "A (ships): every part in one list grouped by where it comes from; a row with text cmux owns folds open to it. The guidance editor sits below.",
      props: { layout: "list" },
    },
    document: {
      note: "B: every text open, one page to read top to bottom. Long, and the counts-only rows get lost between the texts.",
      props: { layout: "document" },
    },
    split: {
      note: "C: rows left, the picked row's text right. Good on a wide pane; on a narrow one the text column is cramped.",
      props: { layout: "split" },
    },
    "saved-for-folder": {
      note: "A replacement saved for this folder: the editor opens on This Folder with it, and Use Default can remove it.",
      props: { layout: "list", saved: { project: "Answer in short sentences. Run tests before you report." } },
    },
    remote: {
      note: "A chat on another computer: counts only, no text, and the editor reads only.",
      props: { layout: "list", remote: true },
    },
    loading: { note: "Before acpmux answers.", props: { layout: "list", pending: true } },
    failed: {
      note: "acpmux refused or is not running: the reason, nothing else.",
      props: { layout: "list", fails: true },
    },
  },
});
