// The Chief web page's transcript (ChiefWeb.tsx loads this chunk once the page knows who is signed
// in, beside the ticket and the socket): the read-only virtual transcript and its row registry, the
// heaviest part of the page. The header, the composer and the sign-in states draw without it, as
// the guest page's do (agent-session/guest/GuestTranscript.tsx).
import { createContext, useContext, useSyncExternalStore, type ComponentProps } from "react";
import { VirtualTranscript } from "../agent-session/acpmux/VirtualTranscript";
import { readOnlyRegistry } from "../agent-session/acpmux/rows/registry";
import { GuestActionsBoundary } from "../agent-session/acpmux/conversation/GuestActionsBoundary";
import { toggleTurnFold } from "../agent-session/acpmux/conversation/turns";
import type { AcpmuxRow } from "../agent-session/acpmux/model";
import type { ChiefTranscript } from "./transcript";

export function ChiefTranscriptView({
  transcript,
  rows,
  working,
  sessionId,
  expanded,
  setExpanded,
}: {
  transcript: ChiefTranscript;
  rows: readonly AcpmuxRow[];
  working: boolean;
  sessionId: string;
  expanded: Set<string>;
  setExpanded: (update: (open: Set<string>) => Set<string>) => void;
}) {
  return (
    <GuestActionsBoundary>
      <LiveTranscriptContext.Provider value={transcript}>
        <VirtualTranscript
          rows={rows}
          sessionId={sessionId}
          expanded={expanded}
          onToggleActivity={(id, covers) => setExpanded((open) => toggleTurnFold([], open, id, covers))}
          working={working}
          registry={chiefRegistry}
          readOnly
        />
      </LiveTranscriptContext.Provider>
    </GuestActionsBoundary>
  );
}

// The virtualizer holds stable row shells while each mounted reply subscribes to its tokens.
const LiveTranscriptContext = createContext<ChiefTranscript | undefined>(undefined);
const Assistant = readOnlyRegistry.assistant!;
function LiveAssistant(props: ComponentProps<typeof Assistant>) {
  const transcript = useContext(LiveTranscriptContext)!;
  const row = useSyncExternalStore(
    (listener) => transcript.subscribeRow(props.row.id, listener),
    () => transcript.row(props.row.id) ?? props.row,
  );
  return <Assistant {...props} row={row} />;
}
const chiefRegistry = { ...readOnlyRegistry, assistant: LiveAssistant };
