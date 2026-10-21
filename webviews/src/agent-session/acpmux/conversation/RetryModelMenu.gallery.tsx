// l10n-allow-file: gallery fixtures (model names, a prompt and a reply), not shipped UI.
// Retry's model menu in a prompt's action row (MessageActions.tsx RetryModelMenu): Claude Code's list as a chat
// reports it, releases and its own aliases mixed (Lawrence 2026-10-20: a raw list, the check
// against the name, one model twice), drawn as the pane's native-look menu in two sections.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";

/** What Claude Code's chat lists: the catalog's releases, its aliases and a pinned 1M variant. */
const claudeModels = [
  { id: "claude-opus-5-5", name: "Claude Opus 5.5" },
  { id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5" },
  { id: "claude-haiku-4-5", name: "Claude Haiku 4.5" },
  { id: "opus", name: "Opus" },
  { id: "opus[1m]", name: "Opus · 1M context" },
  { id: "opusplan", name: "Opus plan · Sonnet execute" },
  { id: "sonnet", name: "Sonnet" },
  { id: "haiku", name: "Haiku" },
  // An alias the harness named as the release it runs (modelCatalogData.ts foldAliases).
  { id: "fable", name: "Fable 5.1", release: "claude-fable-5-1" },
  { id: "claude-fable-5-1", name: "Fable 5.1" },
  { id: "claude-fable-5-1[1m]", name: "Fable 5.1 · 1M context" },
];

const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Retry with another model" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]') !== null);
};

const prompt = {
  id: "user-1",
  version: 1,
  at: Date.UTC(2026, 9, 20, 21, 41),
  kind: "user" as const,
  seq: 1,
  text: "Add retry to the uploader",
};

export default componentEntry<Record<string, never>>({
  id: "agent-pane.retry-model-menu",
  title: "Retry with another model",
  area: "Agent pane",
  pane: true,
  height: 460,
  widths: { narrow: 320, normal: 420, wide: 560 },
  anchors: [{ selector: ".cv-turn-retry-menu" }],
  covers: ["agent-session/acpmux/conversation/MessageActions.tsx#RetryModelMenu"],
  load: async () => {
    const { UserBubble } = await import("./UserBubble");
    const { TurnActionsContext } = await import("./turnActions");
    const actions = {
      retry: () => {},
      retryWith: { models: claudeModels, current: "claude-opus-5-5", retry: () => {} },
    };
    return function GalleryRetryModelMenu() {
      return (
        // Retry shows on the last ended turn's prompt (VirtualTranscript marks its row retryable).
        <div className="acpmux-row" data-retryable="" style={{ position: "relative", padding: "16px 16px 0" }}>
          <TurnActionsContext.Provider value={actions}>
            <UserBubble row={prompt} text={prompt.text} />
          </TurnActionsContext.Provider>
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("../composerControls.css")]),
  variants: {
    closed: { props: {} },
    open: {
      note: "Models, then Aliases & modes; the current model checked in the trailing column.",
      props: {},
      play: open,
    },
  },
});
