// l10n-allow-file: gallery fixtures (sample prompts and agent errors), not shipped UI.
// cmux's own route on a failed turn (CodeRouterOffer.tsx; Lawrence 2026-10-23: "good opportunity
// for upsell here", on a "Deepseek has no valid API key" card): a key, sign-in or capacity failure
// offers CodeRouter beside Switch model. With a CodeRouter route that serves the chat the action
// moves the chat onto it and sends the turn again; with none it opens the CodeRouter docs. The
// failed turn's footer is the real one (TurnRows.tsx); only the chat's routes are stubbed, as the
// composer's Account menu reads them (`_acpmux/route/list`). Compare arms shows the
// `coderouter-offer` experiment's three placements.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { codeRouterOffer } from "./codeRouterOffer.experiment";

type Props = {
  /// The failing chat's harness: its id and the name the cause line uses.
  harness: { id: string; name: string };
  error: string;
  /// The chat's routes: a CodeRouter one that serves it, none, or CodeRouter already bound.
  routes: "coderouter" | "none" | "on-coderouter";
};

const coderouter = { id: "cmux", name: "cmux model router", kind: "cmux-router" };

const row = (error: string) => ({
  id: "summary-2",
  version: 1,
  at: Date.UTC(2026, 9, 23, 3, 12),
  kind: "turnSummary" as const,
  seq: 2,
  status: "failed" as const,
  durationMs: 4_000,
  error,
  prompt: "Add retries to the fetch helper",
  retryRowId: "user-1",
});

/// Clicks the CodeRouter action; the move never answers, so the card stays on its moving state.
const move: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Use cmux CodeRouter" });
  await ctx.waitFor(() => ctx.document.body.textContent?.includes("Moving to CodeRouter…") ?? false);
};

const deepseek = { id: "deepseek", name: "DeepSeek" };
const claude = { id: "claude", name: "Claude Code" };

export default componentEntry<Props>({
  id: "agent-pane.coderouter-offer",
  title: "CodeRouter on a failed turn",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 360, normal: 460, wide: 640 },
  covers: [
    "agent-session/acpmux/conversation/CodeRouterOffer.tsx",
    "agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter",
  ],
  keywords: ["coderouter", "upsell", "api key", "sign in", "rate limit", "error"],
  load: async () => {
    const { TurnFooter } = await import("./TurnRows");
    const { TurnActionsContext } = await import("./turnActions");
    return function GalleryCodeRouterOffer({ harness, error, routes }: Props) {
      const actions = {
        retry: () => {},
        switchModel: () => {},
        route: { name: harness.name, harness: routes === "on-coderouter" ? "claude-cr" : harness.id },
        ownRoute: {
          find: async () =>
            routes === "coderouter" ? coderouter : routes === "on-coderouter" ? ("on" as const) : undefined,
          // The move waits, so a click shows the moving state.
          use: () => new Promise<void>(() => {}),
        },
      };
      return (
        <div style={{ padding: "16px 16px 0" }}>
          <TurnActionsContext.Provider value={actions}>
            <TurnFooter row={row(error) as never} />
          </TurnActionsContext.Provider>
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    "claude-key": {
      note: "An API key failure on a chat a CodeRouter route serves: one click moves the chat there and sends the turn again.",
      props: { harness: claude, error: "invalid x-api-key", routes: "coderouter" },
    },
    "deepseek-key": {
      note: 'Lawrence\'s card: "DeepSeek has no valid API key". No CodeRouter route serves DeepSeek here, so the action opens the CodeRouter docs.',
      props: { harness: deepseek, error: "Invalid API key: DEEPSEEK_API_KEY is not set", routes: "none" },
    },
    "sign-in": {
      note: "Claude Code signed out: Sign in again stays in the footer; CodeRouter sits beside Switch model.",
      props: { harness: claude, error: "Invalid API key · Please run /login", routes: "coderouter" },
    },
    "rate-limited": {
      note: "Capacity: Retry is the filled way out, Switch model and CodeRouter after it.",
      props: { harness: claude, error: "API Error: 529 overloaded_error", routes: "coderouter" },
    },
    "on-coderouter": {
      note: "A chat on CodeRouter already: no CodeRouter action, the card as before.",
      props: { harness: claude, error: "invalid x-api-key", routes: "on-coderouter" },
    },
    moving: {
      note: "After the click: the action says it is moving the chat until acpmux answers.",
      props: { harness: claude, error: "invalid x-api-key", routes: "coderouter" },
      play: move,
    },
  },
  experiment: {
    definition: codeRouterOffer,
    script: [
      // Runs on a variant whose chat a CodeRouter route serves (claude-key, first), in every arm.
      { name: "move to CodeRouter", run: move },
    ],
  },
});
