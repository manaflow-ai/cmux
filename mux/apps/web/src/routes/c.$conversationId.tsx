import type { Participant } from "@mux/protocol";
import { useSuspenseQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState, useSyncExternalStore, type FormEvent, type KeyboardEvent } from "react";
import { viewerQuery } from "../chat/queries.ts";

export const Route = createFileRoute("/c/$conversationId")({
  component: Thread,
});

function Thread() {
  const { conversationId } = Route.useParams();
  const { session } = Route.useRouteContext();
  const { data: viewer } = useSuspenseQuery(viewerQuery(session.source));
  const store = session.store(conversationId, viewer.id);
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [draft, setDraft] = useState("");

  const conversation = state.conversation;
  if (!conversation) return <p className="empty">Connecting…</p>;
  const byId = new Map<string, Participant>(conversation.participants.map((p) => [p.id, p]));
  const rows = [...conversation.messages, ...state.pending.map((p) => p.message)];
  const typingNames = state.typing.map((id) => byId.get(id)?.displayName ?? id);

  const submit = (event?: FormEvent) => {
    event?.preventDefault();
    const text = draft.trim();
    if (!text) return;
    store.send([{ type: "text", text }]);
    setDraft("");
  };
  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) submit(event);
  };

  return (
    <div className="conversation">
      <header className="thread-header">
        <span className="thread-title">{conversation.title}</span>
        <span className="thread-subtitle">
          {conversation.participants.map((p) => p.displayName).join(", ")}
          {state.connected ? "" : " · reconnecting"}
        </span>
      </header>
      <ol
        className="messages"
        ref={(node) => node?.lastElementChild?.scrollIntoView({ block: "end" })}
      >
        {rows.map((m, index) => {
          const mine = m.senderId === viewer.id;
          const sender = byId.get(m.senderId);
          const showName =
            !mine &&
            rows[index - 1]?.senderId !== m.senderId &&
            conversation.participants.length > 2;
          return (
            <li key={m.id} className={mine ? "bubble-row mine" : "bubble-row"}>
              {showName ? <span className="sender">{sender?.displayName}</span> : null}
              <span className={m.status?.state === "sending" ? "bubble sending" : "bubble"}>
                {m.parts.map((p, i) => (p.type === "text" ? <span key={i}>{p.text}</span> : null))}
              </span>
            </li>
          );
        })}
        {typingNames.length > 0 ? (
          <li className="bubble-row">
            <span className="bubble typing" aria-label={`${typingNames.join(", ")} typing`}>
              •••
            </span>
          </li>
        ) : null}
      </ol>
      <form className="composer" onSubmit={submit}>
        <textarea
          rows={1}
          value={draft}
          placeholder="Message"
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={onKeyDown}
        />
        <button type="submit" disabled={!draft.trim()} aria-label="Send">
          ↑
        </button>
      </form>
    </div>
  );
}
