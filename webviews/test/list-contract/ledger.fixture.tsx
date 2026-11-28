// l10n-allow-file: fixture sessions, not shipped UI.
// Costs (History > Costs): one row per session in the range, windowed by ui/VirtualList.
import { useCallback } from "react";
import { LedgerScreen } from "../../src/agent-session/acpmux/ledger/LedgerScreen";
import "../../src/ui/ui.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/ledger/ledger.css";
import { listFixture } from "./listFixture";

const UNTIL = Date.UTC(2026, 10, 18, 9);
type Session = { sessionId: string; title: string; costUsd: number; turns: number; lastAt: number };
const none = () => {};

export default listFixture<Session>({
  source: "agent-session/acpmux/ledger/LedgerScreen.tsx#LedgerScreen",
  rows: ".cst-item",
  scroller: ".cst-list",
  // VirtualList overscan={8}: 8 rows of 52 px past each edge, under one 600 px viewport.
  overscan: { rows: 8 },
  item: (index, n) => ({
    sessionId: `s${index}`,
    title: `Session ${index + 1}`,
    // Most expensive first, as the ledger sorts.
    costUsd: (n - index) / 100,
    turns: 1 + (index % 9),
    lastAt: UNTIL - index * 60_000,
  }),
  render: function Render({ items }) {
    const load = useCallback(
      () =>
        Promise.resolve({
          range: { since: UNTIL - 7 * 86_400_000, until: UNTIL },
          totals: { costUsd: 0, turns: 0, sessions: items.length },
          rows: items.map((item) => ({ ...item, harnessCostUsd: item.costUsd, models: [], pullRequests: [] })),
          rollups: {},
        }),
      [items],
    );
    return (
      <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
        <LedgerScreen load={load} openSession={none} />
      </div>
    );
  },
  skip: {
    change: "the ledger has no one-row update: a read replaces the whole answer",
    select: "a row opens its chat; the ledger has no selection",
  },
});
