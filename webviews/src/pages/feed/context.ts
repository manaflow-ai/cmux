// What every Feed view gets, and the rules they share about it.
import type { KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import type { FeedSnapshot, FeedStore } from "./store";
import type { ViewItem } from "./types";

/** What every Feed view gets. */
export interface FeedProps {
  store: FeedStore;
  snap: FeedSnapshot;
  strings: Strings;
}

/** A plain key: no Cmd, Ctrl or Option (those belong to the app's key dispatcher). */
export function plain(event: KeyboardEvent): boolean {
  return !event.metaKey && !event.ctrlKey && !event.altKey;
}

/** The owner is reachable and this page's link is up: answers and triage may be sent. */
export function canChange(snap: FeedSnapshot): boolean {
  return snap.link !== "disconnected" && snap.view?.connection.state === "connected";
}

export function isPending(snap: FeedSnapshot, item: ViewItem): boolean {
  return item.pending || snap.inflight.has(item.id);
}
