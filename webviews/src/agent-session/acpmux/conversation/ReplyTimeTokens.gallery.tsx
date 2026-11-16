// l10n-allow-file: gallery fixture counts, not shipped UI; every shown word comes from the catalog.
// The reply time's tooltip, its token block laid out three ways, from a real Claude turn (7 model
// calls whose context ended at 139.9K, which read 930.9K from the prompt cache over those calls) and a
// real Codex one. The `rows` look ships (turnTokensModel.ts `replyTimeDetail`): one count per row, the
// input labelled as its calls added up, the context apart from that sum. References:
// codex/live/sidebar-context-window-usage-card, claude/live/status-context-window-usage-popover,
// cmux/live/status-context-wheel-tooltip.
import { componentEntry } from "../../../gallery/format";
import type { TurnTokenSplit } from "../model";

type Look = "rows" | "one-line" | "context-first";
type Props = { look: Look; turns: readonly { words: string; split: TurnTokenSplit }[] };

/// A Claude turn of 7 calls (an acpmux turn_result next to its Claude Code transcript).
const CLAUDE: TurnTokenSplit = {
  output: 5_127,
  input: 13,
  cacheRead: 930_880,
  cacheWrite: 14_211,
  context: 139_922,
  calls: 7,
};
/// A Codex turn of 22 calls (its rollout's token_count events): its input counts the cached part,
/// which acpmux takes out (hub/turn_usage.rs), and it names no call count.
const CODEX: TurnTokenSplit = { output: 4_017, input: 314_899, cacheRead: 3_021_696, cacheWrite: 0, context: 170_741 };
/// A turn an older acpmux recorded: no context, no call count.
const OLDER: TurnTokenSplit = { output: 23_702, input: 112, cacheRead: 4_530_027, cacheWrite: 124_616 };

const TURNS = [
  { words: "1m 16s", split: CLAUDE },
  { words: "4m 2s", split: CODEX },
  { words: "9m 31s", split: OLDER },
];

export default componentEntry<Props>({
  id: "agent-pane.reply-time-tokens",
  title: "Reply time tooltip: input once, cached and uncached, and the context",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/conversation/TurnTokens.tsx", "agent-session/acpmux/tokenSplit.ts"],
  // A narrow pane too: each row stays one count, its longest (the input) wrapping in the tooltip.
  widths: { narrow: 320, normal: 760 },
  load: async () => {
    const { compactTokens, replyTimeDetail, tokenRows } = await import("./turnTokensModel");
    const { useT, usePaneLanguage } = await import("../i18n");
    return function ReplyTimeTokens({ look, turns }: Props) {
      const t = useT();
      const language = usePaneLanguage();
      const text = (words: string, split: TurnTokenSplit) => {
        const head = t("turn.worked", { time: words });
        if (look === "rows") return replyTimeDetail(t, language, [head], split) ?? "";
        const rows = tokenRows(t, language, split);
        if (look === "one-line") return [head, ...rows].join(" · ");
        // Context first: how full the chat is, then what the turn spent.
        const { context, ...spent } = split;
        if (!context) return [head, ...rows].join("\n");
        const contextRow = t("turn.tokens.contextRow", { tokens: compactTokens(language, context) });
        return [head, contextRow, ...tokenRows(t, language, spent)].join("\n");
      };
      return (
        <div style={{ display: "flex", flexDirection: "column", alignItems: "flex-start", gap: 16, padding: 24 }}>
          {turns.map(({ words, split }) => (
            <div
              key={words}
              className="ui-title-tooltip ui-glass"
              data-gallery-tooltip={look}
              style={{ position: "static" }}
            >
              {text(words, split)}
            </div>
          ))}
        </div>
      );
    };
  },
  variants: {
    rows: { props: { look: "rows", turns: TURNS } },
    "one-line": { props: { look: "one-line", turns: TURNS } },
    "context-first": { props: { look: "context-first", turns: TURNS } },
  },
});
