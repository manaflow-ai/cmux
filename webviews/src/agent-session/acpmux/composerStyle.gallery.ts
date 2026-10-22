// l10n-allow-file: gallery fixtures (sample chats and model names), not shipped UI.
// The composer's two styles side by side (Settings > Agent Chat > Composer Style, cmux.json
// `agentPane.display.composer.style`, chatDisplay.ts `composerStyle`). Leo 2026-10-21: "we can have
// the alt composer like chatgpt styled but for now just have "minimal" be the claude thing". The
// same new Codex chat in both: a folder and this computer, GPT-6-Astra on High, Full access.
// Minimal, the default, is Claude Code's box, the mode, model and effort in a quiet row under it,
// the strip a tab on the card. Codex, the alternate (ChatGPT style), lays the same controls out as
// Codex desktop: the folder and computer in a tray tucked under the box's top edge, then one row
// inside the box under the prompt, + and the mode on the left, the model and effort, the mic and
// Send on the right (composerStyle.css).
// test/composer-style-codex.test.ts measures it.
import { agentPaneEntry } from "../../gallery/format";
import { CWD, noChat, session } from "../../gallery/fixtures/acpmux";
import { COMPOSER_STYLE_KEY } from "./chatDisplay";
import type { AcpmuxSnapshot } from "./model";

const effort = {
  id: "effort",
  name: "Reasoning",
  category: "thought_level",
  currentValue: "high",
  options: [
    { value: "low", name: "Low" },
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" },
    { value: "xhigh", name: "Extra High" },
  ],
};

const modes = {
  currentModeId: "full-access",
  availableModes: [
    { id: "read-only", name: "Read only", description: "Read files; ask before edits and commands." },
    { id: "auto", name: "Default", description: "Edit and run in the workspace; ask outside it." },
    { id: "full-access", name: "Full access", description: "Edit and run anything without asking." },
  ],
};

/** A new Codex chat in a project, before its first send: the strip shows the folder and computer. */
const newCodexChat: AcpmuxSnapshot = noChat([session({ sessionId: "older", title: "An older chat" })], {
  summary: {
    sessionId: "",
    cwd: CWD,
    branch: "main",
    harness: "codex",
    model: "gpt-6-astra",
    effort: "high",
    configOptions: [effort],
    modes,
  },
});

const ready = { newSession: true, cwd: CWD };

export default agentPaneEntry({
  id: "agent-pane.composer-style",
  title: "Composer styles (Minimal, Codex)",
  area: "Agent pane",
  height: 320,
  widths: { narrow: 420, normal: 720, wide: 1100 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/Composer.tsx#Composer",
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
    "agent-session/acpmux/chatDisplay.ts#resolveChatDisplay",
  ],
  variants: {
    minimal: {
      note: "Minimal, the default (Claude Code): the strip a tab on the card; + and the mic in the box; the mode, model and effort in the quiet row under it.",
      ready,
      snapshot: newCodexChat,
    },
    codex: {
      note: "Codex, the alternate (ChatGPT style): the folder and computer in a tray under the box's top edge; + and Full access left, the model and effort, the mic and Send right, in the box.",
      ready,
      snapshot: newCodexChat,
      display: { [COMPOSER_STYLE_KEY]: "codex" },
    },
  },
});
