// A forum post, reply or search tool call (forumCalls.ts) as its own card in place of the raw MCP
// row: the thread's title as a link into it, its space, reply count and state; a search lists its
// hits. Leo, 2026-11-22 07:44Z: "you guys are also using the forum? or not as much? i wonder if
// that's also grounds for a new type of tool call appearance in the gui".
//
// `look` picks one of the gallery's arms (ForumCallCard.gallery.tsx); the transcript draws "card".
import type { ReactNode } from "react";
import type { AcpmuxActivity } from "../model";
import { useT, type Translate } from "../i18n";
import { AlertCircle, Envelope, Magnifier } from "./icons";
import type { ForumCall, ForumThreadRef } from "./forumCalls";
import "./ForumCallCard.css";

export type ForumCardLook = "line" | "card" | "quote";

/// Hits shown under a search's line.
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
  const icon = failed ? <AlertCircle /> : call.tool === "search" ? <Magnifier /> : <Envelope />;
  const line = headLine(t, call);
  return (
    <div
      className={`cv-forum-call is-${look}${failed ? " is-failed" : ""}`}
      data-forum-call={call.tool}
      data-status={call.status}
      data-tool-id={item.tool?.id}
    >
      <div className={`cv-tool cv-forum-call__line${running ? " is-live" : " is-strong"}`}>
        <span className="cv-tool__icon">{icon}</span>
        <span className="cv-tool__text">{line}</span>
        {look === "line" && call.thread && !failed && <ThreadInline t={t} thread={call.thread} />}
      </div>
      {failed && call.error && <div className="cv-forum-call__error">{call.error}</div>}
      {look !== "line" && call.thread && !failed && (
        <ThreadBlock t={t} thread={call.thread} body={look === "quote" ? call.body : undefined} />
      )}
      {call.tool === "search" && !running && !failed && call.hits.length > 0 && (
        <ul className="cv-forum-call__hits">
          {call.hits.slice(0, HITS_SHOWN).map((hit, at) => (
            <li key={hit.number ?? at} className="cv-forum-call__hit">
              <ThreadTitle t={t} thread={hit} />
              <Meta t={t} thread={hit} />
              {look === "quote" && hit.snippet && <div className="cv-forum-call__snippet">{hit.snippet}</div>}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function headLine(t: Translate, call: ForumCall): string {
  const space = call.thread?.space ?? "";
  const query = call.query ?? "";
  if (call.status === "failed") return t(`forumCall.failed.${call.tool}`);
  switch (call.tool) {
    case "post":
      return t(call.status === "running" ? "forumCall.posting" : "forumCall.posted", {
        space: space || t("forumCall.forum"),
      });
    case "reply":
      return call.status === "running" || !space ? t("forumCall.replying") : t("forumCall.replied", { space });
    case "search": {
      if (call.status === "running") return t("forumCall.searching", { query });
      const n = call.hits.length;
      if (n === 0) return t("forumCall.found.none", { query });
      return n === 1 ? t("forumCall.found.one", { query }) : t("forumCall.found.other", { query, count: String(n) });
    }
  }
}

function ThreadTitle({ t, thread }: { t: Translate; thread: ForumThreadRef }) {
  const title = thread.title ?? (thread.number ? `#${thread.number}` : "");
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
  if (thread.number)
    parts.push(
      <span key="n" className="cv-forum-call__number">
        #{thread.number}
      </span>,
    );
  if (thread.space) parts.push(<span key="s">{thread.space}</span>);
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
      <Meta t={t} thread={{ ...thread, space: undefined }} />
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
