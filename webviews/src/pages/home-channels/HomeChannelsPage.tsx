// The channels Home: the rail, the open conversation's header, timeline and composer, and the
// thread panel. A view over the Home owners (HomeChannelsStore); no business rules live here.
// View state only: which message has its inline editor open (Up in an empty composer opens it on
// my last message) and whether the switcher shows.
import { useMemo, useState, useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { Composer } from "./Composer";
import { conversationName, lastEditable, others, railSections, timelineRows, withDraft } from "./model";
import { Rail } from "./Rail";
import type { HomeChannelsStore } from "./store";
import { Switcher } from "./Switcher";
import { ThreadPanel } from "./ThreadPanel";
import { Timeline } from "./Timeline";
import type { HomeMessage, HomeParticipant } from "./types";
import { useHomeKeys } from "./useHomeKeys";

export function HomeChannelsPage({ store, strings }: { store: HomeChannelsStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [switcher, setSwitcher] = useState(false);
  // One inline editor at a time, in the surface it was opened from (the thread root shows in both).
  const [editing, setEditing] = useState<{ id: string; surface: "main" | "thread" } | undefined>();
  const { t, format } = strings;
  const me = snap.me?.id;
  const open = snap.selected ? snap.conversations.get(snap.selected) : undefined;
  const rows = useMemo(
    () => withDraft(timelineRows(snap.messages, snap.unseen, me, snap.threadsSeen), snap.draft),
    [snap.messages, snap.unseen, me, snap.threadsSeen, snap.draft],
  );
  const people = useMemo(() => {
    const map = new Map<string, HomeParticipant>();
    for (const conversation of snap.conversations.values()) for (const p of conversation.participants) map.set(p.id, p);
    if (snap.me) map.set(snap.me.id, snap.me);
    return map;
  }, [snap.conversations, snap.me]);
  const mentionable = useMemo(() => others(open, me), [open, me]);
  const online = snap.connection === "online";
  useHomeKeys({
    openSwitcher: () => setSwitcher(true),
    move: (delta, unreadOnly) => {
      const { channels, direct } = railSections(snap.conversations.values());
      const order = [...channels, ...direct];
      const n = order.length;
      const start = order.findIndex((c) => c.id === snap.selected);
      const base = start < 0 ? (delta > 0 ? -1 : n) : start;
      for (let step = 1; step <= n; step += 1) {
        const next = order[(((base + delta * step) % n) + n) % n];
        if (next && (!unreadOnly || next.unread > 0)) {
          void store.select(next.id);
          return;
        }
      }
    },
    escape: () => {
      if (switcher) setSwitcher(false);
      else if (editing) setEditing(undefined);
      else if (snap.thread) store.openThread(undefined);
      else return false;
      return true;
    },
  });
  const name = open ? conversationName(open, me) : "";
  const place = open?.kind === "group" ? `#${name}` : name;
  // The draft's author shows the growing reply; a "typing" line for it would repeat that.
  const typingNames = snap.typing
    .filter((id) => id !== me && id !== snap.draft?.participant)
    .map((id) => people.get(id)?.name ?? id);
  const editActions = (surface: "main" | "thread") => ({
    editing: editing?.surface === surface ? editing.id : undefined,
    onEditStart: (message: HomeMessage) => setEditing({ id: message.id, surface }),
    onEditEnd: () => setEditing(undefined),
    onEdit: (message: HomeMessage, text: string) => store.edit(message, text),
    onRetract: (message: HomeMessage) => void store.retract(message),
  });
  return (
    <div className={`hc-page${snap.thread ? " with-thread" : ""}`}>
      <Rail
        conversations={snap.conversations}
        me={me}
        selected={snap.selected}
        strings={strings}
        onSelect={(id) => {
          setEditing(undefined);
          void store.select(id);
        }}
        onOpenSwitcher={() => setSwitcher(true)}
      />
      <section className="hc-main" aria-label={place}>
        <header className="hc-main-header">
          <h1 className="hc-main-title">
            {open?.kind === "group" && (
              <span className="hc-hash" aria-hidden="true">
                #
              </span>
            )}
            {name}
          </h1>
          {!online && (
            <output className="hc-connection">
              {t(snap.connection === "connecting" ? "connection.connecting" : "connection.offline")}
            </output>
          )}
          {open && open.kind === "group" && (
            <span className="hc-members" title={format("header.members", String(open.participants.length))}>
              <span className="hc-members-faces" aria-hidden="true">
                {open.participants.slice(0, 3).map((p) => (
                  <Avatar key={p.id} participant={p} size={22} />
                ))}
              </span>
              <span className="hc-members-count" aria-hidden="true">
                {open.participants.length}
              </span>
              <span className="hc-visually-hidden">{format("header.members", String(open.participants.length))}</span>
            </span>
          )}
        </header>
        {snap.error && (
          <output className="hc-error selectable">
            <span>{snap.error}</span>
            <button type="button" onClick={() => store.dismissError()}>
              {t("error.dismiss")}
            </button>
          </output>
        )}
        <Timeline
          conversation={snap.selected}
          rows={rows}
          people={people}
          me={me}
          strings={strings}
          loadingOlder={snap.loadingOlder}
          onLoadOlder={() => void store.loadOlder()}
          onOpenThread={(root) => store.openThread(root)}
          onReact={(message, value) => void store.react(message, value)}
          {...editActions("main")}
        />
        <div className="hc-typing" aria-live="polite">
          {typingNames.length === 1
            ? format("typing.one", typingNames[0]!)
            : typingNames.length > 1
              ? t("typing.many")
              : ""}
        </div>
        {open && (
          <Composer
            key={open.id}
            strings={strings}
            placeholder={format("composer.placeholder", place)}
            label={format("composer.placeholder", name)}
            disabled={!online}
            people={mentionable}
            onEditLast={() => {
              const last = lastEditable(snap.messages, me);
              if (last) setEditing({ id: last.id, surface: "main" });
            }}
            onSend={(text) => store.send(text)}
          />
        )}
      </section>
      {snap.thread && (
        <ThreadPanel
          key={snap.thread}
          root={snap.thread}
          place={place}
          messages={snap.messages}
          people={people}
          mentionable={mentionable}
          me={me}
          strings={strings}
          canSend={online}
          onClose={() => store.openThread(undefined)}
          onSend={(text) => store.send(text, snap.thread)}
          onReact={(message, value) => void store.react(message, value)}
          {...editActions("thread")}
        />
      )}
      {switcher && (
        <Switcher
          conversations={snap.conversations}
          me={me}
          strings={strings}
          onPick={(id) => {
            setSwitcher(false);
            setEditing(undefined);
            void store.select(id);
          }}
          onClose={() => setSwitcher(false)}
        />
      )}
    </div>
  );
}
