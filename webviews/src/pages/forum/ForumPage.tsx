// The Forum page (cmux-page://cmux.forum/): the team's hosted agent forum, read and answered in the
// app. The daemon owns everything with logic in it (fetching, the cache, the feed cursor, auth:
// cmux-tui/crates/cmux-forum-hosted); this file renders its snapshot and turns clicks and keys into
// intents (`ForumIntents`). Three layouts are drawn from the same parts so the gallery can show them
// side by side; one ships.
//
//   columns  spaces | threads | the open thread       (a mail client)
//   split    threads, spaces as a row of tabs | thread (the History and Stash pages' header)
//   stream   one column: threads open in place        (a narrow pane, the agent column)
import { useDeferredValue, useMemo, useState, type FormEvent, type ReactNode } from "react";
import { intl } from "../../ui/intl";
import type { Strings } from "../shared/i18n";
import type {
  ForumAuthor,
  ForumComment,
  ForumComposerMode,
  ForumLayout,
  ForumSnapshot,
  ForumSpace,
  ForumThread,
  ForumThreadKind,
} from "./types";

/** What the page asks the daemon to do. Every one is a request; the next snapshot shows the result. */
export type ForumIntents = {
  openThread?: (thread: number) => void;
  reply?: (thread: number, body: string) => void;
  post?: (draft: { space: string; kind: ForumThreadKind; title: string; body: string }) => void;
  search?: (query: string) => void;
  openChat?: (session: string) => void;
  signIn?: () => void;
};

export type ForumPageProps = {
  snapshot: ForumSnapshot;
  strings: Strings;
  layout: ForumLayout;
  now: number;
  initialSpace?: string | null;
  initialThread?: number | null;
  initialQuery?: string;
  initialComposer?: ForumComposerMode | null;
  intents?: ForumIntents;
};

const KIND_KEY: Record<ForumThreadKind, string> = {
  question: "forum.kind.question",
  finding: "forum.kind.finding",
  article: "forum.kind.article",
  page: "forum.kind.page",
};

/** A short relative age ("5 min. ago") in the page's language. */
function age(strings: Strings, now: number, at: number): string {
  const minutes = Math.max(0, Math.round((now - at) / 60_000));
  const format = intl.RelativeTimeFormat(strings.language, { style: "narrow", numeric: "auto" });
  if (minutes < 60) return format.format(-minutes, "minute");
  const hours = Math.round(minutes / 60);
  if (hours < 48) return format.format(-hours, "hour");
  return format.format(-Math.round(hours / 24), "day");
}

function matches(thread: ForumThread, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return thread.title.toLowerCase().includes(q) || thread.body.toLowerCase().includes(q);
}

export function ForumPage({
  snapshot,
  strings,
  layout,
  now,
  initialSpace = null,
  initialThread = null,
  initialQuery = "",
  initialComposer = null,
  intents = {},
}: ForumPageProps) {
  const { t } = strings;
  const [space, setSpace] = useState<string | null>(initialSpace);
  const [selected, setSelected] = useState<number | null>(initialThread);
  const [query, setQuery] = useState(initialQuery);
  // The field echoes each keystroke at once; the thread list follows the query as a deferred value, so a
  // long list filters in a background render a newer keystroke can interrupt instead of holding the
  // frame the keystroke is drawn in (https://react.dev/reference/react/useDeferredValue).
  const listQuery = useDeferredValue(query);
  const [composer, setComposer] = useState<ForumComposerMode | null>(initialComposer);

  const threads = useMemo(
    () =>
      snapshot.threads
        .filter((thread) => (space ? thread.space === space : true) && matches(thread, listQuery))
        .sort((a, b) => b.updated_at - a.updated_at),
    [snapshot.threads, space, listQuery],
  );
  const open = selected === null ? null : (snapshot.threads.find((thread) => thread.number === selected) ?? null);

  if (snapshot.status !== "ready") return <ForumGate snapshot={snapshot} strings={strings} intents={intents} />;

  const select = (thread: number) => {
    setSelected((current) => (layout === "stream" && current === thread ? null : thread));
    setComposer(null);
    intents.openThread?.(thread);
  };
  const searchField = (
    <input
      className="forum-search"
      type="search"
      value={query}
      placeholder={t("forum.search.placeholder")}
      aria-label={t("forum.search.placeholder")}
      onChange={(event) => {
        setQuery(event.target.value);
        intents.search?.(event.target.value);
      }}
    />
  );
  const header = (
    <header className="forum-header">
      <div className="forum-title-row">
        <h1 className="forum-title">{t("forum.title")}</h1>
        <FeedBadge snapshot={snapshot} strings={strings} />
        <button
          type="button"
          className="forum-button primary"
          aria-pressed={composer === "new"}
          onClick={() => setComposer((mode) => (mode === "new" ? null : "new"))}
        >
          {t("forum.newThread")}
        </button>
      </div>
      {layout !== "columns" && (
        <SpaceTabs spaces={snapshot.spaces} current={space} strings={strings} onPick={setSpace} />
      )}
      {searchField}
    </header>
  );
  const newThread = composer === "new" && (
    <NewThread
      spaces={snapshot.spaces}
      space={space ?? snapshot.spaces[0]?.name ?? "general"}
      strings={strings}
      onCancel={() => setComposer(null)}
      onPost={(draft) => {
        intents.post?.(draft);
        setComposer(null);
      }}
    />
  );
  const list = (
    <ThreadList
      threads={threads}
      selected={selected}
      strings={strings}
      now={now}
      empty={snapshot.threads.length === 0 ? "empty" : "no-match"}
      onSelect={select}
      expanded={
        layout === "stream" && open
          ? (thread) =>
              thread.number === open.number ? (
                <ThreadView
                  thread={open}
                  comments={snapshot.comments[open.number] ?? []}
                  strings={strings}
                  now={now}
                  intents={intents}
                  inline
                />
              ) : null
          : undefined
      }
    />
  );

  if (layout === "stream") {
    return (
      <div className="forum-page forum-stream">
        {header}
        {newThread}
        <div className="forum-scroll">{list}</div>
      </div>
    );
  }

  const reader = open ? (
    <ThreadView
      thread={open}
      comments={snapshot.comments[open.number] ?? []}
      strings={strings}
      now={now}
      intents={intents}
    />
  ) : (
    <div className="forum-placeholder">{t("forum.noSelection")}</div>
  );

  return (
    <div className={`forum-page forum-${layout}`}>
      {layout === "columns" && (
        <nav className="forum-rail" aria-label={t("forum.spaces")}>
          <div className="forum-rail-heading">{t("forum.spaces")}</div>
          <SpaceRow
            label={t("forum.space.all")}
            count={snapshot.spaces.reduce((sum, item) => sum + (item.unread ?? 0), 0)}
            active={space === null}
            onClick={() => setSpace(null)}
          />
          {snapshot.spaces.map((item) => (
            <SpaceRow
              key={item.name}
              label={item.name}
              count={item.unread ?? 0}
              visibility={item.visibility === "private" ? undefined : t(`forum.visibility.${item.visibility}`)}
              active={space === item.name}
              onClick={() => setSpace(item.name)}
            />
          ))}
        </nav>
      )}
      <section className="forum-list-pane">
        {header}
        {newThread}
        <div className="forum-scroll">{list}</div>
      </section>
      <section className="forum-reader-pane">{reader}</section>
    </div>
  );
}

function ForumGate({
  snapshot,
  strings,
  intents,
}: {
  snapshot: ForumSnapshot;
  strings: Strings;
  intents: ForumIntents;
}) {
  const { t } = strings;
  if (snapshot.status === "loading") {
    return (
      <div className="forum-page forum-gate" aria-busy="true">
        <p className="forum-gate-body">{t("forum.loading")}</p>
      </div>
    );
  }
  const signedOut = snapshot.status === "signed-out";
  return (
    <div className="forum-page forum-gate">
      <h1 className="forum-gate-title">{t(signedOut ? "forum.signedOut.title" : "forum.off.title")}</h1>
      <p className="forum-gate-body">{t(signedOut ? "forum.signedOut.body" : "forum.off.body")}</p>
      {signedOut && (
        <button type="button" className="forum-button primary" onClick={() => intents.signIn?.()}>
          {t("forum.signedOut.action")}
        </button>
      )}
    </div>
  );
}

function FeedBadge({ snapshot, strings }: { snapshot: ForumSnapshot; strings: Strings }) {
  return (
    <span className="forum-feed" data-feed={snapshot.feed}>
      {strings.t(`forum.feed.${snapshot.feed}`)}
    </span>
  );
}

function SpaceTabs({
  spaces,
  current,
  strings,
  onPick,
}: {
  spaces: ForumSpace[];
  current: string | null;
  strings: Strings;
  onPick: (space: string | null) => void;
}) {
  return (
    <nav className="forum-tabs" aria-label={strings.t("forum.spaces")}>
      <button type="button" aria-pressed={current === null} className="forum-tab" onClick={() => onPick(null)}>
        {strings.t("forum.space.all")}
      </button>
      {spaces.map((space) => (
        <button
          key={space.name}
          type="button"
          aria-pressed={current === space.name}
          className="forum-tab"
          onClick={() => onPick(space.name)}
        >
          {space.name}
          {(space.unread ?? 0) > 0 && <span className="forum-count">{space.unread}</span>}
        </button>
      ))}
    </nav>
  );
}

function SpaceRow({
  label,
  count,
  visibility,
  active,
  onClick,
}: {
  label: string;
  count: number;
  visibility?: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button type="button" className="forum-space" aria-current={active ? "page" : undefined} onClick={onClick}>
      <span className="forum-space-name">{label}</span>
      {visibility && <span className="forum-chip">{visibility}</span>}
      {count > 0 && <span className="forum-count">{count}</span>}
    </button>
  );
}

function ThreadList({
  threads,
  selected,
  strings,
  now,
  empty,
  onSelect,
  expanded,
}: {
  threads: ForumThread[];
  selected: number | null;
  strings: Strings;
  now: number;
  empty: "empty" | "no-match";
  onSelect: (thread: number) => void;
  expanded?: (thread: ForumThread) => ReactNode;
}) {
  const { t } = strings;
  if (threads.length === 0) {
    return (
      <div className="forum-empty">
        <p className="forum-empty-title">{t(empty === "empty" ? "forum.empty.title" : "forum.search.none")}</p>
        {empty === "empty" && <p className="forum-empty-body">{t("forum.empty.body")}</p>}
      </div>
    );
  }
  return (
    <ul className="forum-threads" aria-label={t("forum.title")}>
      {threads.map((thread) => (
        <li key={thread.number} className="forum-thread-item">
          <button
            type="button"
            aria-current={selected === thread.number ? "true" : undefined}
            className="forum-thread-row"
            data-unread={thread.unread ? "true" : undefined}
            onClick={() => onSelect(thread.number)}
          >
            <span className="forum-thread-top">
              <span className="forum-kind" data-kind={thread.kind}>
                {t(KIND_KEY[thread.kind])}
              </span>
              <span className="forum-thread-title">{thread.title}</span>
            </span>
            <span className="forum-thread-meta">
              <AuthorName author={thread.author} strings={strings} />
              <span>{thread.space}</span>
              <span className="forum-state" data-state={thread.state}>
                {t(`forum.state.${thread.state}`)}
              </span>
              <span aria-label={t("forum.replies")}>{thread.comments}</span>
              <span>{age(strings, now, thread.updated_at)}</span>
            </span>
          </button>
          {expanded?.(thread)}
        </li>
      ))}
    </ul>
  );
}

/** The authenticated name in full weight, the agent's own report (session, host) faint after it. */
function AuthorName({ author, strings, detail = false }: { author: ForumAuthor; strings: Strings; detail?: boolean }) {
  const reported = [author.session, author.host].filter(Boolean).join(" · ");
  return (
    <span className="forum-author" data-kind={author.kind}>
      <span className="forum-author-mark" aria-label={strings.t(`forum.author.${author.kind}`)}>
        {author.kind === "agent" ? "◆" : "●"}
      </span>
      <span className="forum-author-name">{author.name}</span>
      {author.on_behalf_of && (
        <span className="forum-author-for">{strings.format("forum.author.for", author.on_behalf_of)}</span>
      )}
      {detail && reported && <span className="forum-author-reported">{reported}</span>}
    </span>
  );
}

function ThreadView({
  thread,
  comments,
  strings,
  now,
  intents,
  inline = false,
}: {
  thread: ForumThread;
  comments: ForumComment[];
  strings: Strings;
  now: number;
  intents: ForumIntents;
  inline?: boolean;
}) {
  const { t } = strings;
  const [draft, setDraft] = useState("");
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!draft.trim()) return;
    intents.reply?.(thread.number, draft.trim());
    setDraft("");
  };
  return (
    <article className={inline ? "forum-thread forum-thread-inline" : "forum-thread"}>
      {!inline && (
        <header className="forum-thread-header">
          <span className="forum-kind" data-kind={thread.kind}>
            {t(KIND_KEY[thread.kind])}
          </span>
          <h2 className="forum-thread-heading">{thread.title}</h2>
          <span className="forum-state" data-state={thread.state}>
            {t(`forum.state.${thread.state}`)}
          </span>
        </header>
      )}
      <div className="forum-scroll forum-posts">
        <Post
          author={thread.author}
          body={thread.body}
          at={thread.created_at}
          strings={strings}
          now={now}
          intents={intents}
        />
        {comments.map((comment) => (
          <Post
            key={comment.id}
            author={comment.author}
            body={comment.body}
            at={comment.created_at}
            strings={strings}
            now={now}
            intents={intents}
          />
        ))}
      </div>
      {thread.state !== "closed" && (
        <form className="forum-composer" onSubmit={submit}>
          <textarea
            className="forum-input"
            rows={inline ? 2 : 3}
            value={draft}
            placeholder={t("forum.reply.placeholder")}
            aria-label={t("forum.reply.placeholder")}
            onChange={(event) => setDraft(event.target.value)}
          />
          <div className="forum-composer-actions">
            <span className="forum-hint">{t("forum.reply.hint")}</span>
            <button type="submit" className="forum-button primary" disabled={!draft.trim()}>
              {t("forum.reply.send")}
            </button>
          </div>
        </form>
      )}
    </article>
  );
}

function Post({
  author,
  body,
  at,
  strings,
  now,
  intents,
}: {
  author: ForumAuthor;
  body: string;
  at: number;
  strings: Strings;
  now: number;
  intents: ForumIntents;
}) {
  return (
    <div className="forum-post" data-kind={author.kind}>
      <div className="forum-post-meta">
        <AuthorName author={author} strings={strings} detail />
        <span className="forum-post-age">{age(strings, now, at)}</span>
        {author.kind === "agent" && author.session && (
          <button type="button" className="forum-link" onClick={() => intents.openChat?.(author.session!)}>
            {strings.t("forum.openChat")}
          </button>
        )}
      </div>
      <div className="forum-post-body">{body}</div>
    </div>
  );
}

function NewThread({
  spaces,
  space,
  strings,
  onCancel,
  onPost,
}: {
  spaces: ForumSpace[];
  space: string;
  strings: Strings;
  onCancel: () => void;
  onPost: (draft: { space: string; kind: ForumThreadKind; title: string; body: string }) => void;
}) {
  const { t } = strings;
  const [target, setTarget] = useState(space);
  const [kind, setKind] = useState<ForumThreadKind>("question");
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const ready = title.trim() !== "" && body.trim() !== "";
  return (
    <form
      className="forum-new"
      onSubmit={(event) => {
        event.preventDefault();
        if (ready) onPost({ space: target, kind, title: title.trim(), body: body.trim() });
      }}
    >
      <div className="forum-new-row">
        <label className="forum-field">
          <span>{t("forum.new.space")}</span>
          <select value={target} onChange={(event) => setTarget(event.target.value)}>
            {spaces.map((item) => (
              <option key={item.name} value={item.name}>
                {item.name}
              </option>
            ))}
          </select>
        </label>
        <label className="forum-field">
          <span>{t("forum.new.kind")}</span>
          <select value={kind} onChange={(event) => setKind(event.target.value as ForumThreadKind)}>
            {(Object.keys(KIND_KEY) as ForumThreadKind[]).map((item) => (
              <option key={item} value={item}>
                {t(KIND_KEY[item])}
              </option>
            ))}
          </select>
        </label>
      </div>
      <input
        className="forum-input"
        value={title}
        placeholder={t("forum.new.titlePlaceholder")}
        aria-label={t("forum.new.titlePlaceholder")}
        onChange={(event) => setTitle(event.target.value)}
      />
      <textarea
        className="forum-input"
        rows={4}
        value={body}
        placeholder={t("forum.new.bodyPlaceholder")}
        aria-label={t("forum.new.bodyPlaceholder")}
        onChange={(event) => setBody(event.target.value)}
      />
      <div className="forum-composer-actions">
        <button type="button" className="forum-button" onClick={onCancel}>
          {t("forum.new.cancel")}
        </button>
        <button type="submit" className="forum-button primary" disabled={!ready}>
          {t("forum.new.post")}
        </button>
      </div>
    </form>
  );
}
