// l10n-allow-file: gallery fixture text is deterministic sample context, not shipped copy.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { ContextViewer, type ContextPart } from "./ContextViewer";

const guidance =
  "Read relevant instructions early. Batch independent reads; sequence dependent work. Start long-running work in the background and inspect results before relying on them. Keep reports concise.";

const partsFor = (harness: "Claude Code" | "Codex"): ContextPart[] => [
  {
    id: "harness-base",
    label: "Harness base prompt",
    source: harness,
    scope: "builtin",
    text: "",
    measurement: "unavailable",
    textAvailable: false,
  },
  {
    id: "cmux-guidance",
    label: "cmux guidance",
    source: "cmux NEXT",
    scope: "user",
    text: guidance,
    tokenCount: 48,
    measurement: "estimated",
    channel: "user-context",
  },
  {
    id: "skills",
    label: "Skills listing",
    source: "acpmux",
    scope: "project",
    text: "",
    measurement: "unavailable",
    textAvailable: false,
  },
  {
    id: "mcp",
    label: "MCP server instructions",
    source: "repo MCP",
    scope: "session",
    text: "",
    measurement: "unavailable",
    textAvailable: false,
  },
];

type Props = ComponentProps<typeof ContextViewer>;

const baseline: Props = {
  parts: partsFor("Claude Code"),
  totalTokens: undefined,
  cmuxTokens: 48,
  settings: {
    user: null,
    project: null,
    defaultText: guidance,
  },
  harness: "Claude Code",
  sessionId: "gallery-context-claude",
  onSaveOverride: () => undefined,
  onResetOverride: () => undefined,
};

const presetPlay: Play = async (ctx) => {
  const select = ctx.document.querySelector<HTMLSelectElement>('select[aria-label="Part"]');
  if (!select) throw new Error("editable preset selector did not open");
  select.value = "cmux-system-prompt";
  select.dispatchEvent(new Event("change", { bubbles: true }));
  await ctx.waitFor(
    () =>
      ctx.document.querySelector<HTMLTextAreaElement>("[data-context-editor] textarea")?.value ===
      "Read the project guide first.",
  );
};

const editPlay: Play = async (ctx) => {
  const editor = ctx.document.querySelector<HTMLTextAreaElement>("[data-context-editor] textarea");
  if (!editor) throw new Error("editable cmux guidance part did not open");
  const set = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(editor), "value")!.set!;
  set.call(editor, "Prefer concurrent reads and concise reports.");
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
    baseline: {
      note: "Claude Code context with provider text redacted where the harness does not expose it.",
      props: baseline,
    },
    codex: {
      note: "Codex context uses the same source labels while preserving unavailable provider text.",
      props: { ...baseline, parts: partsFor("Codex"), harness: "Codex", sessionId: "gallery-context-codex" },
    },
    "edit-cmux-guidance": {
      note: "A separate next-session editor saves a cmux override while the current context rows stay read-only.",
      props: baseline,
      play: editPlay,
    },
    "preset-prompt": {
      play: presetPlay,
      note: "A local Claude preset exposes its cmux-owned system prompt as an independently editable part.",
      props: {
        ...baseline,
        settings: {
          ...baseline.settings!,
          parts: {
            "cmux-system-prompt": {
              label: "Preset system prompt",
              user: null,
              project: "Read the project guide first.",
              defaultText: "You are a coding assistant.",
            },
          },
        },
      },
    },
    "existing-project-override": {
      note: "A project override replaces the user value and is reset independently.",
      props: {
        ...baseline,
        settings: {
          user: "User guidance",
          project: "Project guidance takes precedence",
          defaultText: guidance,
        },
      },
    },
    "remote-read-only": {
      note: "Remote clients can inspect the report but cannot edit local cmux settings.",
      props: {
        ...baseline,
        parts: partsFor("Codex"),
        harness: "Codex",
        sessionId: "gallery-context-remote",
        settings: undefined,
        onSaveOverride: undefined,
        onResetOverride: undefined,
      },
    },
    "disabled-guidance": {
      note: "A saved empty project override disables cmux guidance for new sessions in that project.",
      props: {
        ...baseline,
        settings: { user: null, project: "", defaultText: guidance },
      },
    },
    empty: {
      note: "A session that has not emitted context yet.",
      props: { ...baseline, parts: [] },
    },
    loading: { note: "The context request is in flight.", props: { ...baseline, loading: true } },
  },
});
