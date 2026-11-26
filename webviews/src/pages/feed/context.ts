// What every Feed view gets, and the rules they share about it.
import type { KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import type { ChoiceSelection } from "./model";
import type { FeedSnapshot, FeedStore } from "./store";
import type { ViewItem, FeedApproveScope } from "./types";

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

/** The store's row handlers, one set per store: a row or card gets the same functions on every
 * render (rows are memo), and calls them with its own id. */
export interface RowActions {
  select(id: string): void;
  open(id: string): void;
  selectReport(id: string): void;
}

const rowActionsByStore = new WeakMap<FeedStore, RowActions>();

export function rowActions(store: FeedStore): RowActions {
  let actions = rowActionsByStore.get(store);
  if (!actions) {
    actions = {
      select: (id) => store.select(id),
      open: (id) => store.open(id),
      selectReport: (id) => store.selectReport(id),
    };
    rowActionsByStore.set(store, actions);
  }
  return actions;
}

/** What one request's answer controls read of the snapshot: whether it is pending, whether answers may
 * be sent, and this request's own drafts. Each field is a value (or a draft object that changes only
 * when this request's draft does), so a row can compare it field by field and ignore the rest of the
 * snapshot (a selection, a read, a new clock). */
export interface AnswerState {
  pending: boolean;
  disabled: boolean;
  scope: FeedApproveScope | undefined;
  choices: Record<string, ChoiceSelection> | undefined;
  reply: string | undefined;
}

export function answerState(snap: FeedSnapshot, item: ViewItem): AnswerState {
  return {
    pending: isPending(snap, item),
    disabled: !canChange(snap, item),
    scope: snap.drafts.scopes[item.id],
    choices: snap.drafts.choices[item.id],
    reply: snap.drafts.replies[item.id],
  };
}
