// The Inbox page tab (FeedInboxView, FeedInboxHeader): connection tabs GitHub / Feed / Reports, the
// filter field, the category menu, Mark All Read of what it shows, Refresh while GitHub is on, Add
// connection; the grouped list (Needs you, Today, Earlier) beside the selected item's detail. The
// Reports tab shows the reports basket in place of the list and its detail.
import { useState, type KeyboardEvent } from "react";
import { Button } from "../../ui/Button";
import { Tabs, TabsList, TabsTrigger } from "../../ui/Tabs";
import { isPending, plain, type FeedProps } from "./context";
import { AnswerControls } from "./AnswerControls";
import { FeedIcon } from "./icons";
import { useButtonMenu } from "./menus";
import {
  allItems,
  CATEGORIES,
  CATEGORY_LABEL,
  entryOf,
  inboxLines,
  isArchived,
  isGitHub,
  isHydrated,
  isOpenRequest,
  isRequest,
  isUnread,
  moveSelection,
  shownItem,
  type FeedLine,
  type InboxConnection,
} from "./model";
import { EmptyState, FeedLines, FeedRow, Glyph, PosterLine, PromptSummary } from "./parts";
import { ReportsView } from "./ReportsView";
import type { GitHubAction, GitHubDetail, ViewItem } from "./types";

export function InboxView(props: FeedProps) {
  const { store, snap, strings } = props;
  const { t } = strings;
  const groups = snap.view?.groups ?? [];
  const shown = shownItem(groups, snap.selection);
  const lines = inboxLines(groups, shown?.id, (item) => isPending(snap, item), t);
  const items = allItems(groups);
  const compact = snap.route.density === "compact";
  const keys = (event: KeyboardEvent) => {
    if (!plain(event)) return;
    if (event.key === "ArrowDown") store.select(moveSelection(lines, shown?.id, 1));
    else if (event.key === "ArrowUp") store.select(moveSelection(lines, shown?.id, -1));
    else if (event.key === "Enter" && shown) store.open(shown.id);
    else return;
    event.preventDefault();
  };
  if (snap.filter.connection === "reports")
    return (
      <div className="feed-inbox" data-density={snap.route.density} data-tab="reports">
        <InboxHeader {...props} hasUnread={false} onListKeys={keys} />
        <ReportsView {...props} />
      </div>
    );
  const filtered = snap.filter.query !== "" || snap.filter.category !== "all";
  return (
    <div className="feed-inbox" data-density={snap.route.density}>
      <div className="feed-inbox-column">
        <InboxHeader {...props} hasUnread={items.some(isUnread)} onListKeys={keys} />
        {lines.length === 0 && !isHydrated(snap.view) ? (
          <div className="feed-inbox-list" />
        ) : lines.length === 0 ? (
          <EmptyState text={t(filtered ? "feed.noMatches" : "feed.empty")} />
        ) : (
          <div className="feed-inbox-list">
            <FeedLines
              lines={lines}
              strings={strings}
              now={snap.now}
              label={t("feed.inboxTitle")}
              compact={compact}
              scrollParent=".feed-inbox-list"
              onSelect={(id) => store.select(id)}
              onOpen={(id) => store.open(id)}
              onKeyDown={keys}
            />
          </div>
        )}
      </div>
      <div className="feed-inbox-detail">
        {shown ? <InboxDetail {...props} item={shown} /> : <EmptyState text={t("feed.selectInboxItem")} size={44} />}
      </div>
    </div>
  );
}

interface HeaderProps extends FeedProps {
  hasUnread: boolean;
  onListKeys: (event: KeyboardEvent) => void;
}

/** Connection tabs and the compact triage controls. */
function InboxHeader({ store, snap, strings, hasUnread, onListKeys }: HeaderProps) {
  const { t } = strings;
  const [menu, openMenu] = useButtonMenu();
  const connection = snap.filter.connection;
  const fieldKeys = (event: KeyboardEvent<HTMLInputElement>) => {
    if (plain(event) && event.key === "Escape" && snap.filter.query) {
      store.setQuery("");
      event.preventDefault();
      return;
    }
    onListKeys(event);
  };
  return (
    <header className="feed-inbox-header">
      <div className="feed-tabs">
        <Tabs
          className="feed-tab-list"
          value={connection}
          onValueChange={(value) => store.setConnection(value as InboxConnection)}
        >
          <TabsList>
            <TabsTrigger value="github" className="feed-tab" title={t("feed.github")}>
              <FeedIcon name="brand.github" size={12} />
              <span className="feed-tab-label">{t("feed.github")}</span>
            </TabsTrigger>
            <TabsTrigger value="feed" className="feed-tab" title={t("feed.title")}>
              <FeedIcon name="inbox" size={12} />
              <span className="feed-tab-label">{t("feed.title")}</span>
            </TabsTrigger>
            {snap.view?.reports.available !== false ? (
              <TabsTrigger value="reports" className="feed-tab" title={t("reports.title")}>
                <FeedIcon name="agent.chat" size={12} />
                <span className="feed-tab-label">{t("reports.title")}</span>
              </TabsTrigger>
            ) : null}
          </TabsList>
        </Tabs>
        <button
          type="button"
          className="feed-add"
          title={t("feed.addConnection")}
          aria-label={t("feed.addConnection")}
          onClick={() => store.addConnection()}
        >
          <FeedIcon name="action.add" size={12} />
          <span className="feed-add-label">{t("feed.addConnection")}</span>
        </button>
      </div>
      {connection === "reports" ? null : (
        <div className="feed-triage">
          <FeedIcon name="search" size={14} className="feed-triage-search" />
          <input
            className="feed-filter"
            type="search"
            value={snap.filter.query}
            placeholder={t("feed.filterInbox")}
            aria-label={t("feed.filterInbox")}
            onChange={(event) => store.setQuery(event.target.value)}
            onKeyDown={fieldKeys}
          />
          <Button
            variant="ghost"
            size="sm"
            icon
            aria-label={t("feed.filterInbox")}
            title={t("feed.filterInbox")}
            data-filtered={snap.filter.category === "all" ? undefined : ""}
            onClick={(event) =>
              openMenu(
                event,
                CATEGORIES.map((category) => ({
                  id: category,
                  label: t(CATEGORY_LABEL[category]),
                  disabled: category === snap.filter.category,
                  run: () => store.setCategory(category),
                })),
              )
            }
          >
            <FeedIcon name="filter" size={14} solid={snap.filter.category !== "all"} />
          </Button>
          <Button
            variant="ghost"
            size="sm"
            icon
            aria-label={t("feed.markAllRead")}
            title={t("feed.markAllRead")}
            disabled={!hasUnread}
            onClick={() => store.markShownRead()}
          >
            <FeedIcon name="action.confirm" size={14} />
          </Button>
          {snap.view?.github.enabled ? (
            <Button
              variant="ghost"
              size="sm"
              icon
              aria-label={t("feed.refresh")}
              title={t("feed.refresh")}
              onClick={() => store.refresh()}
            >
              <FeedIcon name="action.reload" size={14} />
            </Button>
          ) : null}
        </div>
      )}
      {menu}
    </header>
  );
}

/** The selected item: toolbar, full prompt, diff, GitHub card, answer form, thread. */
function InboxDetail({ store, snap, strings, item }: FeedProps & { item: ViewItem }) {
  const groups = snap.view?.groups ?? [];
  const entry = entryOf(groups, item.id);
  const thread = entry ? [entry.item, ...entry.members].filter((member) => member.id !== item.id) : [];
  return (
    <div className="feed-detail">
      <DetailToolbar store={store} snap={snap} strings={strings} item={item} />
      <div className="feed-detail-scroll">
        <div className="feed-detail-head">
          <Glyph item={item} />
          <div className="feed-detail-titles">
            <h2 className="feed-detail-title">{item.title}</h2>
            <PosterLine item={item} strings={strings} now={snap.now} />
          </div>
        </div>
        {item.github ? <GitHubSummary detail={item.github} /> : null}
        <PromptSummary item={item} full />
        {isGitHub(item) && item.github_actions ? (
          <GitHubActions key={item.id} store={store} snap={snap} strings={strings} item={item} />
        ) : null}
        {isRequest(item) && item.poster.kind !== "integration" ? (
          <AnswerControls item={item} store={store} snap={snap} strings={strings} density="detail" />
        ) : null}
        {thread.length ? (
          <div className="feed-thread">
            {thread.map((member) => {
              const line: Extract<FeedLine, { type: "row" }> = {
                type: "row",
                id: member.id,
                entry: { id: member.id, item: member, members: [], unread: isUnread(member) },
                threadCount: 1,
                pending: isPending(snap, member),
                selected: false,
              };
              return (
                <FeedRow
                  key={member.id}
                  line={line}
                  strings={strings}
                  now={snap.now}
                  onSelect={() => store.select(member.id)}
                  onOpen={() => store.open(member.id)}
                />
              );
            })}
          </div>
        ) : null}
      </div>
    </div>
  );
}

/** Done (archive), Snooze, Decline. An open request can only be answered or declined (feed.md 3.6),
 * so Done and Snooze wait until it closes. */
function DetailToolbar({ store, strings, item }: FeedProps & { item: ViewItem }) {
  const { t } = strings;
  const [menu, openMenu] = useButtonMenu();
  return (
    <div className="feed-detail-toolbar">
      {isOpenRequest(item) ? (
        <Button size="sm" onClick={() => store.decline(item.id)}>
          {t("answer.decline")}
        </Button>
      ) : (
        <>
          <Button
            variant="ghost"
            size="sm"
            onClick={(event) =>
              openMenu(event, [
                { id: "hour", label: t("toolbar.snoozeHour"), run: () => store.snooze(item.id, "hour") },
                { id: "tomorrow", label: t("toolbar.snoozeTomorrow"), run: () => store.snooze(item.id, "tomorrow") },
              ])
            }
          >
            <FeedIcon name="action.snooze" size={12} />
            {t("toolbar.snooze")}
          </Button>
          <Button size="sm" disabled={isArchived(item)} onClick={() => store.archive(item.id)}>
            {t("toolbar.done")}
          </Button>
        </>
      )}
      {menu}
    </div>
  );
}

/** The live GitHub content the owner keeps for the item. */
function GitHubSummary({ detail }: { detail: GitHubDetail }) {
  return (
    <div className="feed-github">
      <span className="feed-github-title">{detail.title}</span>
      <span className="feed-github-ref">
        {detail.repo}
        {detail.number !== undefined ? `#${detail.number}` : ""}
      </span>
      {detail.body ? <p className="feed-github-body">{detail.body}</p> : null}
      {detail.branch ? (
        <span className="feed-github-line">
          <FeedIcon name="git.branch" size={12} />
          {detail.branch}
        </span>
      ) : null}
      {detail.checks.length ? (
        <ul className="feed-github-checks">
          {detail.checks.map((check) => (
            <li
              key={check.name}
              className="feed-github-line"
              data-failed={check.conclusion === "failure" ? "" : undefined}
            >
              <FeedIcon name={check.conclusion === "failure" ? "status.error" : "status.success"} size={12} />
              {check.name + (check.conclusion ? `: ${check.conclusion}` : "")}
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

const GITHUB_BUTTONS: ReadonlyArray<[GitHubAction, string, string]> = [
  ["open", "feed.openOnGitHub", "link.external"],
  ["checkout", "feed.checkout", "git.branch"],
  ["start_agent", "feed.startAgent", "agent.chat.new"],
  ["approve", "answer.approve", "action.confirm"],
  ["request_changes", "answer.requestChanges", "action.review"],
];

/** The app's GitHub actions for the item (it types into a terminal or opens the browser). */
function GitHubActions({ store, snap, strings, item }: FeedProps & { item: ViewItem }) {
  const { t } = strings;
  const [comment, setComment] = useState("");
  const supported = new Set(item.github_actions ?? []);
  const { pending, error } = snap.github;
  const post = () => {
    const text = comment.trim();
    if (!text || pending || !supported.has("comment")) return;
    setComment("");
    void store.githubAction(item.id, "comment", text);
  };
  return (
    <div className="feed-github-actions">
      <span className="feed-github-actions-title">{t("feed.githubActions")}</span>
      <div className="feed-answer-row">
        {GITHUB_BUTTONS.filter(([action]) => supported.has(action)).map(([action, label, icon]) => (
          <Button
            key={action}
            size="sm"
            variant={action === "approve" ? "solid" : "subtle"}
            disabled={pending}
            onClick={() => void store.githubAction(item.id, action)}
          >
            <FeedIcon name={icon} size={12} />
            {t(label)}
          </Button>
        ))}
      </div>
      {error ? (
        <span className="feed-github-error" role="alert">
          <FeedIcon name="status.warning" size={12} />
          {error}
        </span>
      ) : null}
      <div className="feed-answer-row feed-reply-row">
        <input
          className="feed-field"
          type="text"
          value={comment}
          placeholder={t("feed.comment")}
          aria-label={t("feed.comment")}
          onChange={(event) => setComment(event.target.value)}
          onKeyDown={(event) => {
            if (plain(event) && event.key === "Enter" && !event.nativeEvent.isComposing) {
              event.preventDefault();
              post();
            }
          }}
        />
        {supported.has("comment") ? (
          <Button size="sm" disabled={pending || !comment.trim()} onClick={post}>
            {t("feed.comment")}
          </Button>
        ) : null}
      </div>
    </div>
  );
}
