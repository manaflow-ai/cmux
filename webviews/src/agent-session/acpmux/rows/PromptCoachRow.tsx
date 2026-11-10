import { memo, useState } from "react";
import { PromptCoachCard } from "../conversation/PromptCoachCard";
import { usePromptCoachOn } from "../chatDisplay";
import { type RowProps } from "./rowProps";
import { dismissPromptCoach } from "./rowActions";

/// The cards that already drew in this page: one drawn again (scrolled out and back, a rebuild)
/// never plays its entrance twice.
const entered = new Set<string>();
/// A card whose record is this new arrived while the chat was open, so it fades in once.
const FRESH_MS = 15_000;

function enters(id: string, at: number): boolean {
  if (entered.has(id)) return false;
  entered.add(id);
  return Date.now() - at < FRESH_MS;
}

/// A prompt coach card under the turn its rewrite landed in (conversation/PromptCoachCard.tsx). Its ×
/// hides it for good on this device (direct.ts dismissPromptCoach). Off in Settings, it draws nothing.
export const PromptCoachRow = memo(
  function PromptCoachRow({ row }: RowProps) {
    const on = usePromptCoachOn();
    const [enter] = useState(() => enters(row.id, row.at));
    const coach = row.coach;
    if (!coach || !on) return null;
    return (
      <PromptCoachCard coach={coach} enter={enter} onDismiss={() => dismissPromptCoach(row.id, coach.sessionId)} />
    );
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
/// A prompt coach card in a replayed or read-only subagent transcript: Copy, no ×, which would act on
/// the live chat.
export const ReadOnlyPromptCoachRow = memo(
  function ReadOnlyPromptCoachRow({ row }: RowProps) {
    const on = usePromptCoachOn();
    return row.coach && on ? <PromptCoachCard coach={row.coach} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
