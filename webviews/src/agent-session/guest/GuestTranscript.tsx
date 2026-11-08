// The guest page's transcript, its own chunk (GuestPage.tsx loads it with `loadGuestTranscript`):
// the owner's VirtualTranscript, read only inside GuestActionsBoundary, and the fed client that
// folds the room's records. These carry most of the page's script, so the page draws its frame
// (header, transcript area, composer at the bottom) and opens the room's socket first, while this
// loads beside them (Leo, 2026-11-07: the composer "was the only thing that was seen for a while
// and then it got repositioned").
import { AcpmuxDirectClient, nextFrame } from "../acpmux/direct";
import { GuestActionsBoundary } from "../acpmux/conversation/GuestActionsBoundary";
import type { AcpmuxSnapshot } from "../acpmux/model";
import { VirtualTranscript } from "../acpmux/VirtualTranscript";
import { installGuestHost } from "./guestHost";

/**
 * The page's own setup (main.tsx, never the gallery): no owner host, before anything here can ask
 * one (guestHost.ts), and draws on the display frame. main.tsx runs it as this chunk arrives, ahead
 * of the chat, which asks for the chunk after it.
 */
export function installGuestPage(): void {
  installGuestHost();
  AcpmuxDirectClient.scheduleFrame = nextFrame;
}

/** The part of the fed client the page uses. */
export type GuestFeed = Pick<AcpmuxDirectClient, "feed" | "dispose">;

/** A client the room's frames feed, drawing one chat's snapshot through `onSnapshot`. */
export const feedClient = (sessionId: string, onSnapshot: (snapshot: AcpmuxSnapshot) => void): GuestFeed =>
  AcpmuxDirectClient.fed(sessionId, onSnapshot);

export type GuestTranscriptProps = {
  snapshot: AcpmuxSnapshot;
  sessionId: string;
  expanded: Set<string>;
  onToggle: (id: string, covers?: readonly string[]) => void;
  hasMore: boolean;
  onLoadOlder: () => Promise<void>;
};

export function GuestTranscript({
  snapshot,
  sessionId,
  expanded,
  onToggle,
  hasMore,
  onLoadOlder,
}: GuestTranscriptProps) {
  return (
    <GuestActionsBoundary>
      <VirtualTranscript
        rows={snapshot.rows}
        sessionId={sessionId}
        expanded={expanded}
        onToggleActivity={onToggle}
        working={snapshot.isWorking}
        readOnly
        // The thread rail is the owner's pane chrome; here it drew a lone tick at the page's edge.
        showMinimap={false}
        canLoadOlder={hasMore}
        historyFrom={snapshot.historyFrom}
        onLoadOlder={onLoadOlder}
      />
    </GuestActionsBoundary>
  );
}
