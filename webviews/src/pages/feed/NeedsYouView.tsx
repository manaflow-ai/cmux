// Home's pinned Needs you section (FeedNeedsYouView): the Feed's open requests, the ones its list
// pins on top, read from the same owner (no second store). Rows: what it is, who asked and its
// one-click answers at the end; cards: the Feed's request cards; bar: one line with the count and
// the first request (a click opens it). Past the limit the rest are only counted. It draws
// nothing while nothing waits. The integrations hub's approvals (Chief only, hubApprovals.ts) come
// first, as cards with Approve and Deny, up to HUB_ROWS (FeedNeedsYouSection.hubRows).
import { useSyncExternalStore } from "react";
import { cx } from "../../ui/cx";
import { HubApprovalCard } from "./HubApprovalCard";
import type { HubApprovals, HubSnapshot } from "./hubApprovals";
import { isPending, type FeedProps } from "./context";
import { AnswerControls } from "./AnswerControls";
import { answersInline, groupEntries, relativeTime, splitNeedsYou } from "./model";
import { Glyph, RequestCard } from "./parts";
import type { ViewItem } from "./types";

/** How many hub approval cards show before the header counts the rest. */
export const HUB_ROWS = 2;

const NO_HUB: HubSnapshot = { rows: [] };
const noHub = () => () => undefined;

export function NeedsYouView(props: FeedProps & { hub?: HubApprovals }) {
  const { store, snap, strings, hub } = props;
  const { t, format } = strings;
  const hubRows = useSyncExternalStore(hub?.subscribe ?? noHub, hub?.getSnapshot ?? (() => NO_HUB)).rows;
  const requests = snap.view ? groupEntries(snap.view, "needs_you").map((entry) => entry.item) : [];
  const feedTotal = requests.length > 0 ? Math.max(snap.view?.counts.open_requests ?? 0, requests.length) : 0;
  const total = feedTotal + hubRows.length;
  if (total === 0) return null;
  const { style, limit } = snap.route;
  if (style === "bar" && requests.length > 0) {
    const first = requests[0]!;
    return (
      <section className="feed-needs" data-style="bar" aria-label={`${t("group.needsYou")}, ${total}`}>
        <button type="button" className="feed-needs-opener" onClick={() => store.open(first.id)}>
          <Glyph item={{ ...first, row: { ...first.row, urgent: false } }} />
          <span className="feed-needs-text">
            <span className="feed-needs-headline">{`${t("group.needsYou")} ${total}`}</span>
            <span className="feed-needs-meta secondary">{first.row.headline}</span>
          </span>
        </button>
      </section>
    );
  }
  const { shown } = splitNeedsYou(requests, limit);
  const hubShown = hubRows.slice(0, HUB_ROWS);
  const more = Math.max(0, total - shown.length - hubShown.length);
  return (
    <section className="feed-needs" data-style={style} aria-label={`${t("group.needsYou")}, ${total}`}>
      <div className="feed-needs-header">
        <span className="feed-needs-title">{t("group.needsYou")}</span>
        <span className="feed-needs-count feed-num">{total}</span>
        {more > 0 ? <span className="feed-needs-more">{format("needsYou.more", String(more))}</span> : null}
      </div>
      {hub
        ? hubShown.map((row) => <HubApprovalCard key={row.card.approvalId} row={row} hub={hub} strings={strings} />)
        : null}
      {shown.map((item) =>
        style === "cards" ? (
          <RequestCard key={item.id} item={item} store={store} snap={snap} strings={strings} />
        ) : (
          <NeedsYouRow key={item.id} {...props} item={item} />
        ),
      )}
    </section>
  );
}

/** One request: what it is and who asked (a click there opens its source), then its answers. */
function NeedsYouRow({ store, snap, strings, item }: FeedProps & { item: ViewItem }) {
  const who = [item.row.who, item.row.where].filter(Boolean).join(" · ") || item.poster.label;
  return (
    <div className={cx("feed-needs-row", isPending(snap, item) && "pending")} data-item={item.id}>
      <button type="button" className="feed-needs-opener" onClick={() => store.open(item.id)}>
        <Glyph item={item} />
        <span className="feed-needs-text">
          <span className="feed-needs-headline">{item.row.headline}</span>
          <span className="feed-needs-meta">{`${who} · ${relativeTime(item.created_at, snap.now, strings.language)}`}</span>
        </span>
      </button>
      {answersInline(item) ? (
        <div className="feed-needs-answers">
          <AnswerControls item={item} store={store} snap={snap} strings={strings} density="inline" />
        </div>
      ) : null}
    </div>
  );
}
