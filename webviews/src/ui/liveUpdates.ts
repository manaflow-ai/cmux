import { createContext, useContext } from "react";

/** A retained, offscreen subtree keeps its DOM and state but needs no live UI subscriptions.
 * Consumers read their current source again when the row is revealed. */
export const LiveUpdatesContext = createContext(true);
export const useLiveUpdates = () => useContext(LiveUpdatesContext);
