// l10n-allow-file: gallery fixtures (model names, a prompt and a reply), not shipped UI.
// Retry's model menu in a prompt's action row (RetryModelMenu.tsx): Claude Code's list as a chat reports it,
// releases, its own aliases and older versions mixed, the aliases' releases twice (Leo 2026-10-20:
// Opus 5.5, Sonnet 5.5 and Haiku 5.5 each twice, a stale tail of old models, the bare system font),
// drawn as the composer's model menu: the top models, then older ones under More models.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { topModelsFor } from "../topModels";

/** What Claude Code's chat lists (the list in Leo's screenshot): its aliases named as the releases
 *  they run, its 1M and plan modes, then every release, the aliases' ones again. */
const claudeModels = [
  { id: "opus", name: "Opus 5.5", release: "claude-opus-5-5" },
  { id: "claude-fable-5-1[1m]", name: "Fable 5.1 · 1M context" },
  { id: "sonnet", name: "Sonnet 5.5", release: "claude-sonnet-5-5" },
  { id: "haiku", name: "Haiku 5.5", release: "claude-haiku-5-5" },
  { id: "opus[1m]", name: "Opus · 1M context" },
  { id: "opusplan", name: "Opus plan · Sonnet execute" },
  { id: "sonnet[1m]", name: "Sonnet · 1M context" },
  { id: "claude-fable-5-1", name: "Fable 5.1" },
  { id: "claude-fable-5", name: "Fable 5" },
  { id: "claude-opus-5-5", name: "Opus 5.5" },
  { id: "claude-opus-5", name: "Opus 5" },
  { id: "claude-opus-4-8", name: "Opus 4.8" },
  { id: "claude-opus-4-7", name: "Opus 4.7" },
  { id: "claude-opus-4-6", name: "Opus 4.6" },
  { id: "claude-opus-4-5", name: "Opus 4.5" },
  { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
  { id: "claude-sonnet-5", name: "Sonnet 5" },
  { id: "claude-sonnet-4-6", name: "Sonnet 4.6" },
  { id: "claude-sonnet-4-5", name: "Sonnet 4.5" },
  { id: "claude-haiku-5-5", name: "Haiku 5.5" },
  { id: "claude-haiku-4-5", name: "Haiku 4.5" },
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
  covers: ["agent-session/acpmux/conversation/RetryModelMenu.tsx"],
  load: async () => {
    const { UserBubble } = await import("./UserBubble");
    const { TurnActionsContext } = await import("./turnActions");
    const actions = {
      retry: () => {},
      retryWith: {
        models: claudeModels,
        current: "claude-opus-5-5",
        harness: "Claude Code",
        // The current families, plus the 1M Fable row Claude Code's own menu lists: a shown row
        // with a detail ("1M context"), whose placement retry-model-menu.test.ts measures.
        top: [...(topModelsFor("claude") ?? []), "claude-fable-5-1[1m]"],
        retry: () => {},
      },
    };
    return function GalleryRetryModelMenu() {
      return (
        // Retry shows on the last ended turn's prompt (VirtualTranscript marks its row retryable). The
        // prompt's action row is laid in the turn gap under the row (design/grid.md 5.5), so the row
        // keeps layout containment alone, as the transcript's article rows do: paint containment
        // (styles.css .acpmux-row) would clip the row away and leave Retry unclickable.
        <div
          className="acpmux-row cv-user"
          data-retryable=""
          style={{ position: "relative", padding: "16px 16px 0", contain: "layout" }}
        >
          <TurnActionsContext.Provider value={actions}>
            <UserBubble row={prompt} text={prompt.text} />
          </TurnActionsContext.Provider>
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("../modelPicker.css")]),
  variants: {
    closed: { props: {} },
    open: {
      note: "The top models, the current one checked at the trailing edge, then More models.",
      props: {},
      play: open,
    },
  },
});
