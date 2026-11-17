// The page's side of chat widgets (widgetModel.ts has the ops): one stream of the host's changes
// shared by every card, and the keys each transcript shows merged into one `widget.keep`, as the
// native projection kept each view's keys (`keep(_:owner:)`, MessagesLabHome
// `HomeProjection+Widgets.swift`): the main transcript and an open thread both keep theirs.
import { createContext, useContext, useEffect, useState } from "react";
import type { PageClient } from "../../../shared/pageClient";
import type { HomeMessage, HomeWidgetPart } from "../../../home-channels/types";
import {
  parseWidgetChange,
  parseWidgetSnapshot,
  widgetKey,
  widgetWire,
  WidgetOps,
  type WidgetSnapshot,
} from "./widgetModel";

export interface WidgetService {
  /** The widget's snapshot now, mounting it on first use; undefined: draw the fallback. */
  snapshot(key: string, part: HomeWidgetPart): Promise<WidgetSnapshot | undefined>;
  /** A click on the item drawn for scene node `node`. */
  tap(key: string, node: string): void;
  /** The keys one transcript (`owner`) shows; an empty list releases it. */
  keep(owner: object, keys: readonly string[]): void;
  /** Each widget's new snapshot as it changes; returns the stop. */
  subscribe(listener: (key: string, snapshot: WidgetSnapshot | undefined) => void): () => void;
}

/** The transcript's widget host; absent (a browser, the gallery): every widget shows its fallback. */
export const WidgetContext = createContext<WidgetService | undefined>(undefined);

/** The widget keys of `messages`: each unretracted message's widget parts. */
export function widgetKeys(messages: readonly HomeMessage[]): string[] {
  const keys: string[] = [];
  for (const message of messages) {
    if (message.retracted) continue;
    message.parts.forEach((part, index) => {
      if (part.type === "widget") keys.push(widgetKey(message.id, index));
    });
  }
  return keys;
}

/** The widgets of `host` (CmuxNextHome `HomeMessagesWidgets`). */
export function hostWidgets(host: PageClient): WidgetService {
  const listeners = new Set<(key: string, snapshot: WidgetSnapshot | undefined) => void>();
  const owners = new Map<object, readonly string[]>();
  let sent: string | undefined;
  // The open subscription; each its own, so a stop before its answer ends that one only.
  let current: { ended: boolean; stop?: () => void } | undefined;

  const listen = () => {
    const subscription: { ended: boolean; stop?: () => void } = { ended: false };
    current = subscription;
    void host
      .subscribe<unknown>(WidgetOps.changes, (event) => {
        const change = subscription.ended ? undefined : parseWidgetChange(event);
        if (change) for (const listener of listeners) listener(change.key, change.snapshot);
      })
      .then((unsubscribe) => {
        if (subscription.ended) unsubscribe();
        else subscription.stop = unsubscribe;
      })
      .catch(() => undefined);
  };

  return {
    snapshot: (key, part) =>
      host
        .call<unknown>(WidgetOps.snapshot, { key, widget: widgetWire(part) })
        .then(parseWidgetSnapshot, () => undefined),
    tap: (key, node) => void host.call(WidgetOps.tap, { key, node }).catch(() => undefined),
    keep(owner, keys) {
      if (keys.length) owners.set(owner, keys);
      else owners.delete(owner);
      const all = [...new Set([...owners.values()].flat())].sort();
      const text = all.join("\n");
      if (text === sent) return;
      sent = text;
      void host.call(WidgetOps.keep, { keys: all }).catch(() => undefined);
    },
    subscribe(listener) {
      listeners.add(listener);
      if (listeners.size === 1) listen();
      return () => {
        listeners.delete(listener);
        if (listeners.size || !current) return;
        current.ended = true;
        current.stop?.();
        current = undefined;
      };
    },
  };
}

/** Keeps the widgets of a transcript's loaded messages mounted while it shows them, scrolled away
 * too (the native projection's window, not only the rows on screen), and releases them when it
 * closes. */
export function useWidgetKeep(messages: readonly HomeMessage[]): void {
  const service = useContext(WidgetContext);
  const [owner] = useState(() => ({}));
  const keys = widgetKeys(messages).join("\n");
  useEffect(() => {
    if (service) service.keep(owner, keys ? keys.split("\n") : []);
  }, [service, owner, keys]);
  useEffect(() => () => service?.keep(owner, []), [service, owner]);
}
