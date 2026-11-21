// l10n-allow-file: gallery fixtures (sample chats and prompts), not shipped UI.
// Studio's composer look (composerLook.ts `studio`, Settings' agentPane.composerLook "studio", which
// the Studio add-on look sets): the in-box row laid out as a coding studio's composer draws it.
// The prompt on its own line over one row: the model, the effort and the access chips on the left,
// the attach paperclip and the round accent Send on the right (composerLook.css). The Studio look
// also turns the mic and the context ring off (agentPane.showDictation, agentPane.showContextUsage);
// `studio-own-settings` keeps them on, as the look alone draws them. `standard-beside` is the default
// composer on the same chat, to set beside.
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { assistant, chat, CWD, manySessions, noChat, user } from "../../gallery/fixtures/acpmux";
import { setPreviewComposerLook, type ComposerLook } from "./composerLook";
import { setComposerSettings } from "./composerSettings";
import type { AcpmuxSnapshot } from "./model";

const effort = {
  id: "effort",
  name: "Reasoning",
  category: "thought_level",
  currentValue: "medium",
  options: [
    { value: "low", name: "Low" },
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" },
    { value: "xhigh", name: "Extra High" },
  ],
};

const modes = {
  currentModeId: "default",
  availableModes: [
    { id: "default", name: "Supervised", description: "Ask before changing files or running commands" },
    { id: "acceptEdits", name: "Edit automatically", description: "Make edits without asking" },
    { id: "bypassPermissions", name: "Full access", description: "Run without asking" },
  ],
};

/// A started chat with its modes and effort reported, as a running session reports them.
const startedChat = (harness: "claude" | "codex" = "codex"): AcpmuxSnapshot => {
  const snapshot = chat(
    [
      user("Add a DELETE /todos/:id endpoint and one focused test using the existing test setup.", 12),
      assistant("Added `DELETE /todos/:id` and a test that deletes an item and checks the list.", 11),
    ],
    harness === "codex" ? { harness, model: "gpt-6-astra" } : {},
  );
  snapshot.summary = { ...snapshot.summary!, modes, configOptions: [effort] };
  return snapshot;
};

const runningChat = (): AcpmuxSnapshot => {
  const snapshot = startedChat();
  return { ...snapshot, isWorking: true, summary: { ...snapshot.summary!, steering: true } };
};

/// A new chat before its first send, centred as the reference's empty thread is.
const newChat = (): AcpmuxSnapshot =>
  noChat(manySessions(3), {
    sessionId: "prewarmed",
    summary: {
      sessionId: "prewarmed",
      cwd: CWD,
      harness: "claude",
      model: "claude-opus-5-5",
      turnCount: 0,
      modes: { ...modes, currentModeId: "bypassPermissions" },
      configOptions: [{ ...effort, currentValue: "xhigh" }],
    },
  });

const DRAFT = {
  draft:
    "Work only in the todo-app folder. Add a DELETE /todos/:id endpoint and one focused test using the existing test setup. Keep the change tiny.",
};

/// The settings the Studio add-on look sets beside the composer look.
const studioSettings = () => setComposerSettings({ showDictation: false, showContextUsage: false });

async function look(ctx: PlayContext, which: ComposerLook, own = false) {
  if (!own) studioSettings();
  setPreviewComposerLook(which);
  await ctx.waitFor(() =>
    which === "studio"
      ? ctx.document.querySelector('[data-composer-variant="studio"]')
      : ctx.document.querySelector(".acpmux-composer:not([data-composer-look]):not([data-composer-variant])"),
  );
}

export default agentPaneEntry({
  id: "agent-pane.composer-studio",
  title: "Composer look: Studio",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  anchors: [{ selector: ".acpmux-composer-box" }],
  covers: ["agent-session/acpmux/composerLook.ts", "agent-session/acpmux/ComposerPlusMenu.tsx#ComposerPlusMenu"],
  variants: {
    studio: {
      composerLook: "studio",
      note: "Studio's composer in a started chat: the model, effort and access chips on the left with chevrons and hairlines between, the paperclip and the round accent Send on the right; no mic or ring (the Studio look turns them off).",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "studio"),
    },
    "studio-typed": {
      composerLook: "studio",
      note: "A prompt ready to send: Send is the full accent disc.",
      snapshot: startedChat(),
      ready: DRAFT,
      play: (ctx) => look(ctx, "studio"),
    },
    "studio-running": {
      composerLook: "studio",
      note: "A turn running with an empty prompt: Stop's square on a red disc, as the reference draws it.",
      snapshot: runningChat(),
      play: (ctx) => look(ctx, "studio"),
    },
    "studio-new-chat": {
      composerLook: "studio",
      note: "A new chat centred in the pane (Settings' Empty Chat Message Box: Center), on Claude with Extra High and Full access, as the reference's empty thread.",
      height: 560,
      ready: { newSession: true, cwd: CWD },
      snapshot: newChat(),
      play: async (ctx) => {
        setComposerSettings({ emptyChatComposerPosition: "center" });
        await look(ctx, "studio");
      },
    },
    "studio-own-settings": {
      composerLook: "studio",
      note: "The look alone, with the mic and the context ring still on (their own settings): the ring before the paperclip, the mic between it and Send.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "studio", true),
    },
    "standard-beside": {
      composerLook: "claude",
      note: "Before: the default composer on the same chat, to set beside Studio's; unchanged.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "claude", true),
    },
  },
});
