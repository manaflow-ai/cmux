// l10n-allow-file: gallery fixtures (sample chats and dictated words), not shipped UI.
// Dictation in the chat's real composer (Leo's Claude Code reference, 2026-10-20): the whole pane,
// driven through the host's own bridge (`cmuxAcpmuxBridge.dictation`, AgentPaneDictation's
// updates). Listening keeps the composer one row: "Listening…" in italic while no words came,
// the words streaming into the prompt as they arrive, then the waveform, the composer's one Send (↵)
// and the lit mic. The strip has no send of its own (Leo 2026-11-05: "The dictate button has its own
// send button. We don't need that."). Codex's look draws ChatGPT's row: ✕, the waveform, Stop, Send.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import { setComposerLook } from "./composerLook";
import type { DictationUpdate } from "./dictationText";

const finished = [
  user("Add retries with backoff to the fetch helper", 10),
  assistant("Done: GETs retry, POSTs only with a policy.", 9),
  summary(9, { status: "completed" }),
];

/// A second of speech: one level per update, as the host sends about 12 a second.
const SPEECH = [0.12, 0.35, 0.62, 0.48, 0.81, 0.66, 0.3, 0.74, 0.52, 0.9, 0.58];

type Bridge = { dictation?(update: DictationUpdate): void };

/// Sends the host's dictation updates to the pane, in order, through its bridge.
function deliver(ctx: Parameters<Play>[0], updates: DictationUpdate[]): void {
  const bridge = (ctx.document.defaultView as (Window & { cmuxAcpmuxBridge?: Bridge }) | null)?.cmuxAcpmuxBridge;
  for (const update of updates) bridge?.dictation?.(update);
}

const listening = (text: string): DictationUpdate[] =>
  SPEECH.map((level) => ({ state: "listening", text, level, cancelled: false }));

const waitForWave = (ctx: Parameters<Play>[0]) =>
  ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer .acpmux-dictation-wave"));

const listeningEmpty: Play = async (ctx) => {
  await ctx.click({ selector: "[contenteditable='true']" });
  deliver(ctx, [{ state: "starting", text: "", level: 0, cancelled: false }, ...listening("")]);
  await waitForWave(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-prompt.is-dictating"));
};

const listeningWords: Play = async (ctx) => {
  await ctx.click({ selector: "[contenteditable='true']" });
  deliver(ctx, [
    { state: "starting", text: "", level: 0, cancelled: false },
    { state: "listening", text: "make the retry", level: 0.4, cancelled: false },
    ...listening("make the retry delay grow with each attempt"),
  ]);
  await waitForWave(ctx);
  await ctx.waitFor(() =>
    ctx.document.querySelector(".acpmux-composer-prompt")?.textContent?.includes("grow with each attempt"),
  );
};

const finalizing: Play = async (ctx) => {
  await ctx.click({ selector: "[contenteditable='true']" });
  const text = "make the retry delay grow with each attempt";
  deliver(ctx, [
    { state: "starting", text: "", level: 0, cancelled: false },
    ...listening(text),
    { state: "finalizing", text, level: 0, cancelled: false },
  ]);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer .acpmux-mic[data-state='finalizing']"));
};

/// The same play in Codex's look, shown and not remembered.
const inCodex =
  (play: Play): Play =>
  async (ctx) => {
    setComposerLook("codex", { remember: false });
    await ctx.waitFor(() => ctx.document.querySelector('[data-composer-look="codex"]'));
    await play(ctx);
  };

export default agentPaneEntry({
  id: "agent-pane.composer-dictation",
  title: "Composer dictation (chat)",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 297, normal: 760, wide: 760 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: [
    "agent-session/acpmux/DictationMic.tsx#DictationMic",
    "agent-session/acpmux/DictationListening.tsx#DictationWave",
    "agent-session/acpmux/DictationListening.tsx#DictationStrip",
    "agent-session/acpmux/DictationListening.tsx#DictationCancelButton",
  ],
  variants: {
    idle: {
      note: "Idle: the mic beside Send, nothing else.",
      snapshot: chat(finished),
    },
    "listening-empty": {
      note: "Play: listening before any words: “Listening…” in italic, the waveform, the one Send (↵) and the lit mic, as Claude's composer draws it.",
      snapshot: chat(finished),
      play: listeningEmpty,
    },
    "listening-words": {
      note: "Play: the words stream into the prompt as they are heard; the waveform follows the mic level.",
      snapshot: chat(finished),
      play: listeningWords,
    },
    finalizing: {
      note: "Play: finalizing: the last words land and the wave dims.",
      snapshot: chat(finished),
      play: finalizing,
    },
    "codex-listening-empty": {
      note: "Play, Codex's look: ChatGPT's row: ✕ (drops the words, as Esc), the waveform, Stop (the lit mic, keeps the words) and Send.",
      snapshot: chat(finished),
      play: inCodex(listeningEmpty),
    },
    "codex-listening-words": {
      note: "Play, Codex's look: the words stream in; Send ends the session and sends them once they land.",
      snapshot: chat(finished),
      play: inCodex(listeningWords),
    },
  },
});
