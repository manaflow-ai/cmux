// Home's pinned Needs you section (FeedNeedsYouView): the Feed's open requests, the ones its list
// pins on top, read from the same owner (no second store). Rows: what it is, who asked and its
// one-click answers at the end; cards: the Feed's request cards; bar: one line with the count and
// the first request (a click opens it). Past the limit the rest are only counted. It draws
// nothing while nothing waits.
import { createContext, memo, useContext } from "react";
import { sameJson } from "../../agent-session/acpmux/sameJson";
import { cx } from "../../ui/cx";
import { answerState, isPending, type FeedProps } from "./context";
import { AnswerControls } from "./AnswerControls";
import { answersInline, groupEntries, relativeTime, splitNeedsYou } from "./model";
import { Glyph, RequestCard, type RequestCardProps } from "./parts";
import type { ViewItem } from "./types";

/** The snapshot's clock, read by each row's age (NeedsYouAge) and by no row: a new clock (a selection,
 * a read) draws the ages, not the rows. */
const NeedsYouNow = createContext(0);

export function NeedsYouView(props: FeedProps) {
  const { store, snap, strings } = props;
  const { t, format } = strings;
  const requests = groupEntries(snap.view, "needs_you").map((entry) => entry.item);
  const total = Math.max(snap.view?.counts.open_requests ?? 0, requests.length);
  if (!snap.view || total === 0 || requests.length === 0) return null;
  const { style, limit } = snap.route;
  if (style === "bar") {
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
  const more = Math.max(0, total - shown.length);
  return (
    <section className="feed-needs" data-style={style} aria-label={`${t("group.needsYou")}, ${total}`}>
      <NeedsYouNow.Provider value={snap.now}>
        <div className="feed-needs-header">
          <span className="feed-needs-title">{t("group.needsYou")}</span>
          <span className="feed-needs-count feed-num">{total}</span>
          {more > 0 ? <span className="feed-needs-more">{format("needsYou.more", String(more))}</span> : null}
        </div>
        {shown.map((item) =>
          style === "cards" ? (
            <RequestCard
              key={item.id}
              item={item}
              store={store}
              strings={strings}
              time={relativeTime(item.created_at, snap.now, strings.language)}
              pending={isPending(snap, item)}
              {...answerState(snap, item)}
            />
          ) : (
            <NeedsYouRow
              key={item.id}
              item={item}
              store={store}
              strings={strings}
              pending={isPending(snap, item)}
              {...answerState(snap, item)}
            />
          ),
        )}
      </NeedsYouNow.Provider>
    </section>
  );
}

type RowProps = Omit<RequestCardProps, "time">;

/** One request: what it is and who asked (a click there opens its source), then its answers. Memo:
 * it takes its own part of the snapshot (its item, compared by content as the owner sends every item
 * again, and its answer state), never the snapshot, so a selection, a read or a new clock draws no
 * row whose request did not change. Its age is a leaf of its own (NeedsYouAge). */
const NeedsYouRow = memo(function NeedsYouRow({ item, store, strings, pending, ...answer }: RowProps) {
  const who = [item.row.who, item.row.where].filter(Boolean).join(" · ") || item.poster.label;
  return (
    <div className={cx("feed-needs-row", pending && "pending")} data-item={item.id}>
      <button type="button" className="feed-needs-opener" onClick={() => store.open(item.id)}>
        <Glyph item={item} />
        <span className="feed-needs-text">
          <span className="feed-needs-headline">{item.row.headline}</span>
          <span className="feed-needs-meta">
            {`${who} · `}
            <NeedsYouAge at={item.created_at} language={strings.language} />
          </span>
        </span>
      </button>
      {answersInline(item) ? (
        <div className="feed-needs-answers">
          <AnswerControls item={item} store={store} strings={strings} density="inline" {...answer} />
        </div>
      ) : null}
    </div>
  );
}, sameRow);

function sameRow(a: RowProps, b: RowProps): boolean {
  for (const key in a) {
    if (key === "item") continue;
    if (!Object.is(a[key as keyof RowProps], b[key as keyof RowProps])) return false;
  }
  return Object.keys(a).length === Object.keys(b).length && sameJson(a.item, b.item);
}

/** A request's age at the snapshot's clock: the one part of a row that reads it. */
function NeedsYouAge({ at, language }: { at: ViewItem["created_at"]; language: string }) {
  return relativeTime(at, useContext(NeedsYouNow), language);
}
