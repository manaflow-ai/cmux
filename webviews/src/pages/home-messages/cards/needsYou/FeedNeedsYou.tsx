// The pinned Needs you section under a Chief chat's header: the Feed page itself on `#/needs-you`
// (pages/feed: FeedPage, NeedsYouView), not a second rendering. The same FeedStore reads the daemon's
// feed client (`cmux.feed.view.read {layout: needs_you}`, again on every `cmux.feed.view.changed`), so
// the same requests, answers, pins and refusal toast show here as in the Feed. The host sends the
// route only while the shown chat is a Chief's and Settings > Notifications > Feed > Pin Needs You in
// Chief is on (off by default); off, nothing mounts and nothing reads the Feed. While it shows, the
// host relays `cmux.feed.*` as the Feed page's calls and runs its actions (`cmux.app.action.run`,
// sent here as `needsYou.action`) as the Feed page's (HomeMessagesHost.swift).
import { useState } from "react";
import { createStrings } from "../../../shared/i18n";
import type { PageClient } from "../../../shared/pageClient";
import { FeedPage, rejectText } from "../../../feed/FeedPage";
import feedTable from "../../../feed/generated/strings.json";
import { FeedStore, type FeedStoreOptions } from "../../../feed/store";
import { ACTION_RUN } from "../../../feed/types";
import "../../../feed/styles.css";

/** The host's op that runs the Feed page's actions for this section. */
export const NEEDS_YOU_ACTION = "cmux.home.messages.needsYou.action";

/** The Feed route the host's `needsYou` stream names, or undefined (the section does not show). */
export function parseNeedsYouRoute(event: unknown): string | undefined {
  if (!event || typeof event !== "object" || Array.isArray(event)) return undefined;
  const route = (event as { route?: unknown }).route;
  return typeof route === "string" && route.startsWith("#/needs-you") ? route : undefined;
}

/** `host` as the Feed page's client: its actions go to ``NEEDS_YOU_ACTION``, everything else as it is. */
export function needsYouFeedClient(host: PageClient): PageClient {
  return {
    call: (op, params, options) => host.call(op === ACTION_RUN ? NEEDS_YOU_ACTION : op, params, options),
    subscribe: (stream, onEvent, filter) => host.subscribe(stream, onEvent, filter),
    handle: (op, handler) => host.handle(op, handler),
  };
}

export function FeedNeedsYou({
  host,
  route,
  clock,
}: {
  host: PageClient;
  route: string;
  clock?: FeedStoreOptions["clock"];
}) {
  // One store per section: it reads while mounted (its first listener) and stops when it unmounts.
  const [feed] = useState(() => {
    const strings = createStrings(feedTable);
    const store = new FeedStore(needsYouFeedClient(host), route, {
      rejectText: (reject) => rejectText(reject, strings),
      ...(clock ? { clock } : {}),
    });
    return { store, strings };
  });
  return <FeedPage store={feed.store} strings={feed.strings} />;
}
