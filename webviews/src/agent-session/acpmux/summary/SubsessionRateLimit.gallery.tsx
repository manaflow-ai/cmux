// l10n-allow-file: gallery fixtures (chat names and doing lines), not shipped UI.
// A sub-session's row while acpmux holds its chat on the account's rate limit (Leo: "the old coord
// keeps running into these rate limit spirals"): the row's state reads "rate-limited until
// 14:05Z" (session/list `rateLimitedUntil`, retryState.ts ``heldLabel``), as `acpmux ls` says it.
// Synthetic data.
import { componentEntry } from "../../../gallery/format";
import type { SubsessionRow } from "../subagents/subsessions";

type Props = { rows: SubsessionRow[] };

/// 14:05 UTC on a fixed day, so the row reads the same in every capture.
const RESET = Date.UTC(2026, 10, 17, 14, 5);

const row = (name: string, fields: Partial<SubsessionRow> = {}): SubsessionRow => ({
  sessionId: `session-${name}`,
  harness: "claude",
  name,
  state: "working",
  depth: 0,
  ...fields,
});

export default componentEntry<Props>({
  id: "agent-pane.subsession-rate-limit",
  title: "Sub-session held on a rate limit",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 320, normal: 480, wide: 720 },
  covers: [
    "agent-session/acpmux/summary/SubagentStatusList.tsx#SubagentStatusList",
    "agent-session/acpmux/subagents/retryState.ts",
  ],
  load: async () => {
    const { SubagentStatusList } = await import("./SubagentStatusList");
    const waiting = new Set<string>();
    return function GallerySubsessionRateLimit({ rows }: Props) {
      return (
        <div className="acpmux-shell" style={{ padding: "12px", flexDirection: "column" }}>
          <SubagentStatusList agents={[]} waiting={waiting} subsessions={rows} onOpenSession={() => {}} />
        </div>
      );
    };
  },
  styles: () => import("../styles.css"),
  variants: {
    held: {
      note: "acpmux holds the chat on its account's rate limit: the row's state says until when, in UTC, as `acpmux ls` does.",
      props: { rows: [row("lane/ratelimit-coord", { rateLimitedUntil: RESET })] },
    },
    "held-failed": {
      note: "A held chat whose last turn failed on the 429 and waits to retry: the hold's time reads instead of the retry's count.",
      props: {
        rows: [
          row("lane/ratelimit-coord", {
            state: "failed",
            retry: { attempt: 1, of: 4, reason: "rate_limit", nextAt: RESET },
            rateLimitedUntil: RESET,
          }),
        ],
      },
    },
    "not-held": {
      note: "No hold: the rows read as before, one working and one retrying after a rate limit.",
      props: {
        rows: [
          row("lane/docs-pass", { doing: "Reading sessionList.ts" }),
          row("lane/ratelimit-coord", {
            state: "failed",
            retry: { attempt: 2, of: 4, reason: "rate_limit", nextAt: RESET },
          }),
        ],
      },
    },
  },
});
