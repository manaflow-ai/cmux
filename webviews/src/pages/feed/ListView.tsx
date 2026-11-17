// The right sidebar section (FeedListPane): the title, the badge and Mark All
// Read; open requests as cards with inline answers, pinned on top; then every other item, newest
// first. The owner orders both; this view never sorts.
import type { KeyboardEvent } from "react";
import { Button } from "../../ui/Button";
import { isPending, plain, type FeedProps } from "./context";
import { FeedIcon } from "./icons";
import { groupEntries, isHydrated, moveSelection, restLines } from "./model";
import { EmptyState, FeedLines, RequestCard } from "./parts";

export function ListView({ store, snap, strings }: FeedProps) {
  const { t } = strings;
  const view = snap.view;
  const requests = groupEntries(view, "requests");
  const lines = restLines(view?.groups ?? [], snap.selection, (item) => isPending(snap, item));
  const badge = view?.counts.badge ?? 0;
  const empty = isHydrated(view) && requests.length === 0 && lines.length === 0;
  const keys = (event: KeyboardEvent) => {
    if (!plain(event)) return;
    if (event.key === "ArrowDown") store.select(moveSelection(lines, snap.selection, 1));
    else if (event.key === "ArrowUp") store.select(moveSelection(lines, snap.selection, -1));
    else if (event.key === "Enter" && snap.selection) store.open(snap.selection);
    else return;
    event.preventDefault();
  };
  return (
    <div className="feed-list">
      <header className="feed-list-bar">
        <h1 className="feed-list-title">{t("feed.title")}</h1>
        <span className="feed-badge feed-num" data-hidden={badge === 0 ? "" : undefined} aria-hidden={badge === 0}>
          {badge}
        </span>
        <Button
          variant="ghost"
          size="sm"
          icon
          className="feed-list-mark"
          aria-label={t("feed.markAllRead")}
          title={t("feed.markAllRead")}
          disabled={!view?.counts.unread}
          onClick={() => store.markAllRead()}
        >
          <FeedIcon name="action.confirm" size={14} />
        </Button>
      </header>
      {empty ? (
        <EmptyState text={t("feed.empty")} />
      ) : (
        <div className="feed-list-scroll">
          {requests.map((entry) => (
            <RequestCard key={entry.id} item={entry.item} store={store} snap={snap} strings={strings} />
          ))}
          <FeedLines
            lines={lines}
            strings={strings}
            now={snap.now}
            label={t("feed.title")}
            scrollParent=".feed-list-scroll"
            onSelect={(id) => store.select(id)}
            onOpen={(id) => store.open(id)}
            onKeyDown={keys}
          />
        </div>
      )}
    </div>
  );
}
