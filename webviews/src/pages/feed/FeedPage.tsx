// The Feed page (plans/cmux-next/feed-page.md section 3): one page for the Inbox page tab
// (`#/inbox`), the right sidebar section (`#/list`), and Home's pinned Needs you
// (`#/needs-you`). State lives in `FeedStore`; this file picks the route's view, says when the
// owner is unreachable, and shows refusals as the one toast stack's toast (FeedView).
import { useSyncExternalStore } from "react";
import { NoticeStack } from "../../ui/NoticeStack";
import { useLasting } from "../../ui/lasting";
import type { Strings } from "../shared/i18n";
import type { FeedReject, FeedStore } from "./store";
import { closedStatus } from "./model";
import { InboxView } from "./InboxView";
import { ListView } from "./ListView";
import { NeedsYouView } from "./NeedsYouView";
import { Banner } from "./parts";

/** The refusal toast's text (FeedStrings.reject). */
export function rejectText(reject: FeedReject, strings: Pick<Strings, "t" | "format">): string {
  switch (reject.kind) {
    case "closed":
      return (reject.item && closedStatus(reject.item, strings)) ?? strings.t("owner.refused");
    case "moving":
      return strings.t("owner.moving");
    case "disconnected":
      return strings.t("owner.disconnected");
    case "refused":
      return strings.t("owner.refused");
  }
}

export function FeedPage({ store, strings }: { store: FeedStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = strings;
  // A lost page link says so only once it lasts (a launch, a daemon restart re-read on their own);
  // the owner's own cloud state is said at once, in its words.
  const linkDown = useLasting(snap.link === "disconnected");
  const owner = snap.view?.connection;
  const banner = linkDown
    ? t("owner.disconnected")
    : owner?.state === "disconnected"
      ? owner.reason || t("owner.disconnected")
      : undefined;
  const props = { store, snap, strings };
  const view = snap.route.view;
  return (
    <div className="feed-page" data-view={view} data-surface={snap.route.surface}>
      {banner && view !== "needs-you" ? <Banner text={banner} /> : null}
      {view === "inbox" ? (
        <InboxView {...props} />
      ) : view === "list" ? (
        <ListView {...props} />
      ) : (
        <NeedsYouView {...props} />
      )}
      <NoticeStack queue={store.notices} dismissLabel={t("toast.dismiss")} />
    </div>
  );
}
