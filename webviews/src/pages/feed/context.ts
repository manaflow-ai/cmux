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

/** This page's link is up and the item's owner is reachable: answers and triage may be sent. A local
 * item (GitHub, an update card) lives in the daemon's own owner, so it stays answerable while the
 * cloud owner is unreachable; only a cloud item needs the cloud connection. */
export function canChange(snap: FeedSnapshot, item?: ViewItem): boolean {
  if (snap.link === "disconnected") return false;
  if (item && isLocal(item)) return true;
  return snap.view?.connection.state === "connected";
}

/** The item's home is this machine's owner (`local:<install>`), not the cloud. */
export function isLocal(item: ViewItem): boolean {
  return typeof item.home === "string" && item.home.startsWith("local");
}

export function isPending(snap: FeedSnapshot, item: ViewItem): boolean {
  return item.pending || snap.inflight.has(item.id);
}
