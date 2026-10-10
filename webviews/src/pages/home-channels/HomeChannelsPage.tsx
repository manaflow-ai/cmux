// The channels Home: the rail, the open conversation's timeline and composer, and the thread
// panel. A view over the Home owners (HomeChannelsStore); no business rules live here.
import { useMemo, useState, useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { Composer } from "./Composer";
import { conversationName, railSections, timelineRows } from "./model";
import { Rail } from "./Rail";
import type { HomeChannelsStore } from "./store";
import { Switcher } from "./Switcher";
import { ThreadPanel } from "./ThreadPanel";
import { Timeline } from "./Timeline";
import type { HomeParticipant } from "./types";
import { useHomeKeys } from "./useHomeKeys";

export function HomeChannelsPage({ store, strings }: { store: HomeChannelsStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [switcher, setSwitcher] = useState(false);
  const { t, format } = strings;
  const me = snap.me?.id;
  const open = snap.selected ? snap.conversations.get(snap.selected) : undefined;
  const rows = useMemo(() => timelineRows(snap.messages), [snap.messages]);
  const people = useMemo(() => {
    const map = new Map<string, HomeParticipant>();
    for (const conversation of snap.conversations.values()) for (const p of conversation.participants) map.set(p.id, p);
    if (snap.me) map.set(snap.me.id, snap.me);
    return map;
  }, [snap.conversations, snap.me]);
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
      else if (snap.thread) store.openThread(undefined);
      else return false;
      return true;
    },
  });
  const name = open ? conversationName(open, me) : "";
  const typingNames = snap.typing.filter((id) => id !== me).map((id) => people.get(id)?.name ?? id);
  return (
    <div className={`hc-page${snap.thread ? " with-thread" : ""}`}>
      <Rail
        conversations={snap.conversations}
        me={me}
        selected={snap.selected}
        strings={strings}
        onSelect={(id) => void store.select(id)}
        onOpenSwitcher={() => setSwitcher(true)}
      />
      <section className="hc-main">
        <header className="hc-main-header">
          <span className="hc-main-title">
            {open?.kind === "group" && <span className="hc-hash">#</span>}
            {name}
          </span>
          {open && open.kind === "group" && (
            <span className="hc-main-sub">{format("header.members", String(open.participants.length))}</span>
          )}
          {!online && (
            <span className="hc-connection">
              {t(snap.connection === "connecting" ? "connection.connecting" : "connection.offline")}
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
          onEdit={(message, text) => store.edit(message, text)}
          onRetract={(message) => void store.retract(message)}
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
            placeholder={format("composer.placeholder", open.kind === "group" ? `#${name}` : name)}
            label={format("composer.placeholder", name)}
            disabled={!online}
            onSend={(text) => store.send(text)}
          />
        )}
      </section>
      {snap.thread && (
        <ThreadPanel
          key={snap.thread}
          root={snap.thread}
          messages={snap.messages}
          people={people}
          me={me}
          strings={strings}
          canSend={online}
          onClose={() => store.openThread(undefined)}
          onSend={(text) => store.send(text, snap.thread)}
          onReact={(message, value) => void store.react(message, value)}
          onEdit={(message, text) => store.edit(message, text)}
          onRetract={(message) => void store.retract(message)}
        />
      )}
      {switcher && (
        <Switcher
          conversations={snap.conversations}
          me={me}
          strings={strings}
          onPick={(id) => {
            setSwitcher(false);
            void store.select(id);
          }}
          onClose={() => setSwitcher(false)}
        />
      )}
    </div>
  );
}
