// A call to the agent forum (forumCalls.ts) as its own row in place of the raw shell row: a line in
// the forum's words (what it searched, read, posted or replied on), then the thread or the hits, each
// title a link into its thread. Leo, 2026-11-22 07:44Z: "you guys are also using the forum? or not as
// much? i wonder if that's also grounds for a new type of tool call appearance in the gui".
//
// `look` is the `forum-call-card` experiment's arm (forumCall.experiment.ts); the gallery's
// `agent-pane.forum-call-looks` draws each side by side.
import type { ReactNode } from "react";
import type { AcpmuxActivity } from "../model";
import { useT, type Translate } from "../i18n";
import { signed } from "../../../ui/Typography";
import { AlertCircle, Envelope, Magnifier } from "./icons";
import type { ForumCall, ForumThreadRef } from "./forumCalls";
import type { ForumCallLook } from "./forumCall.experiment";
import "./ForumCallCard.css";

export type ForumCardLook = Exclude<ForumCallLook, "off">;

/// Hits shown under a search's or a list's line; the rest are counted.
const HITS_SHOWN = 5;

export function ForumCallCard({
  item,
  call,
  look = "card",
}: {
  item: AcpmuxActivity;
  call: ForumCall;
  look?: ForumCardLook;
}) {
  const t = useT();
  const running = call.status === "running";
  const failed = call.status === "failed";
  const many = call.action === "search" || call.action === "list";
  const icon = failed ? <AlertCircle /> : many ? <Magnifier /> : <Envelope />;
  const thread = call.thread && hasThread(call.thread) ? call.thread : undefined;
  const shown = call.hits.slice(0, HITS_SHOWN);
  const more = call.hits.length - shown.length;
  return (
    <div
      className={`cv-forum-call is-${look}${failed ? " is-failed" : ""}`}
      data-forum-call={call.action}
      data-status={call.status}
      data-tool-id={item.tool?.id}
    >
      <div className={`cv-tool cv-forum-call__line${running ? " is-live" : " is-strong"}`}>
        <span className="cv-tool__icon">{icon}</span>
        <span className="cv-tool__text">{headLine(t, call)}</span>
        {look === "line" && thread && !many && <ThreadInline t={t} thread={thread} />}
      </div>
      {failed && call.error && !call.refused && <div className="cv-forum-call__error">{call.error}</div>}
      {look !== "line" && thread && !many && (
        <ThreadBlock t={t} thread={thread} body={look === "quote" ? call.body : undefined} />
      )}
      {look !== "line" && many && !running && shown.length > 0 && (
        <ul className="cv-forum-call__hits">
          {shown.map((hit, at) => (
            <li key={`${hit.mark ?? ""}#${hit.number ?? at}`} className="cv-forum-call__hit">
              <ThreadTitle t={t} thread={hit} />
              <Meta t={t} thread={hit} />
              {look === "quote" && hit.snippet && <div className="cv-forum-call__snippet">{hit.snippet}</div>}
            </li>
          ))}
          {more > 0 && (
            <li className="cv-forum-call__more">{signed(t("forumCall.more", { count: String(more) }))}</li>
          )}
        </ul>
      )}
    </div>
  );
}

function hasThread(thread: ForumThreadRef) {
  return Boolean(thread.title || thread.number);
}

/// `#123`, or `hosted#12` when the CLI named the forum.
function refOf(thread: ForumThreadRef | undefined): string {
  return thread?.number ? `${thread.mark ?? ""}#${thread.number}` : "";
}

export function headLine(t: Translate, call: ForumCall): string {
  const ref = refOf(call.thread);
  const query = call.query ?? "";
  const running = call.status === "running";
  if (call.refused) return t("forumCall.refused");
  if (call.status === "failed") return t(`forumCall.failed.${call.action}`);
  switch (call.action) {
    case "search": {
      if (running) return t("forumCall.searching", { query });
      const n = call.hits.length;
      if (n === 0) return t("forumCall.found.none", { query });
      return n === 1 ? t("forumCall.found.one", { query }) : t("forumCall.found.other", { query, count: String(n) });
    }
    case "list": {
      if (running) return t("forumCall.listing");
      const n = call.hits.length;
      if (n === 0) return t("forumCall.listed.none");
      return n === 1 ? t("forumCall.listed.one") : t("forumCall.listed.other", { count: String(n) });
    }
    case "show":
      if (!ref) return t(running ? "forumCall.readingThread" : "forumCall.readThread");
      return t(running ? "forumCall.reading" : "forumCall.read", { ref });
    case "ask":
      return t(running ? "forumCall.asking" : "forumCall.asked");
    case "post":
      return t(running ? "forumCall.posting" : "forumCall.posted");
    case "reply":
      return t(running ? "forumCall.replying" : "forumCall.replied");
    case "close":
      if (running) return t("forumCall.closing", { ref });
      return t(call.stillOpen ? "forumCall.answered" : "forumCall.closed", { ref });
  }
}

function ThreadTitle({ t, thread }: { t: Translate; thread: ForumThreadRef }) {
  const title = thread.title ?? refOf(thread);
  if (!title) return null;
  return thread.url ? (
    <a
      className="cv-forum-call__title"
      href={thread.url}
      rel="noreferrer"
      target="_blank"
      title={t("forumCall.open", { title })}
    >
      {title}
    </a>
  ) : (
    <span className="cv-forum-call__title">{title}</span>
  );
}

function Meta({ t, thread }: { t: Translate; thread: ForumThreadRef }) {
  const parts: ReactNode[] = [];
  const ref = refOf(thread);
  // A thread with no title shows its number as the title, not twice.
  if (ref && thread.title)
    parts.push(
      <span key="n" className="cv-forum-call__number">
        {ref}
      </span>,
    );
  // The CLI's own tag (question, finding, article, research): the thread's data, as it names it.
  if (thread.kind) parts.push(<span key="k">{thread.kind}</span>);
  if (thread.comments !== undefined) parts.push(<span key="c">{replies(t, thread.comments)}</span>);
  if (thread.state === "answered" || thread.state === "closed")
    parts.push(
      <span key="st" className={`cv-forum-call__state is-${thread.state}`}>
        {t(`forumCall.state.${thread.state}`)}
      </span>,
    );
  if (!parts.length) return null;
  return <span className="cv-forum-call__meta">{parts}</span>;
}

function ThreadInline({ t, thread }: { t: Translate; thread: ForumThreadRef }) {
  return (
    <span className="cv-forum-call__inline">
      <ThreadTitle t={t} thread={thread} />
      <Meta t={t} thread={{ ...thread, kind: undefined }} />
    </span>
  );
}

function ThreadBlock({ t, thread, body }: { t: Translate; thread: ForumThreadRef; body?: string }) {
  return (
    <div className="cv-forum-call__thread">
      <ThreadTitle t={t} thread={thread} />
      <Meta t={t} thread={thread} />
      {body && <div className="cv-forum-call__body">{body}</div>}
    </div>
  );
}

function replies(t: Translate, n: number): string {
  if (n === 0) return t("forumCall.replies.none");
  return n === 1 ? t("forumCall.replies.one") : t("forumCall.replies.other", { count: String(n) });
}
