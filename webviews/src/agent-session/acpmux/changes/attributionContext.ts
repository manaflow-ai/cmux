// Where a chat's edit diffs read who wrote their lines (changes/attribution.ts). The pane provides
// it; without it (a gallery, a test, a page with no daemon) the diffs show no markers.
import { createContext } from "react";
import type { AttributionRepo, AttributionStore } from "./attribution";

export type AttributionSource = {
  /// The chat the pane shows: its own turns read as "This chat".
  sessionId: string | undefined;
  store: AttributionStore;
  /// The shown chat's repository and commit; undefined when there is nothing to ask.
  repo(): Promise<AttributionRepo | undefined>;
  /// Scrolls the shown chat to one of its turns (App.tsx `reveal`, the path a turn link takes).
  reveal(turnId: string): void;
};

export const AttributionContext = createContext<AttributionSource | undefined>(undefined);
