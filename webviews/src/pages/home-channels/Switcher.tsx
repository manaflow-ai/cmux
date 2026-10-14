// The Cmd-K palette: conversations, the open conversation's threads and the page's actions in one
// list, ranked by the command palette's own ranker (rankPalette) so it matches the palette's fuzzy
// and acronym rules. The shared primitives own the keyboard, roles and focus: ui/Dialog traps
// focus, makes the page behind inert, closes on a press outside and returns focus; ui/Combobox owns
// the combobox and listbox roles, the arrows and the highlighted row. The best match is always
// highlighted; Return runs the highlighted row, Escape closes.
import { useMemo, useState, type KeyboardEvent, type ReactNode } from "react";
import { rankPalette, type PaletteRankEntry } from "../../palette/ranker";
import { Combobox } from "../../ui/Combobox";
import { Dialog } from "../../ui/Dialog";
import type { Strings } from "../shared/i18n";
import { ConversationAvatar } from "./ConversationAvatar";
import { HomeIcon, type HomeIconName } from "./icons";
import { channelIds, conversationName } from "./model";
import type { ThreadMeta } from "./threads";
import type { HomeConversation } from "./types";

/** A page action the palette offers (the page decides which apply now). */
export interface PaletteAction {
  id: string;
  title: string;
  icon: HomeIconName;
  /** The key that does the same outside the palette. */
  key?: string;
  run(): void;
}

export interface SwitcherProps {
  conversations: ReadonlyMap<string, HomeConversation>;
  /** The open conversation's threads (newest first). */
  threads: readonly ThreadMeta[];
  actions: readonly PaletteAction[];
  me?: string;
  strings: Strings;
  onPick(id: string): void;
  onPickThread(root: string): void;
  onClose(): void;
}

type Item =
  | { kind: "conversation"; id: string; conversation: HomeConversation }
  | { kind: "thread"; id: string; thread: ThreadMeta }
  | { kind: "action"; id: string; action: PaletteAction };

export function Switcher({
  conversations,
  threads,
  actions,
  me,
  strings,
  onPick,
  onPickThread,
  onClose,
}: SwitcherProps) {
  const { t } = strings;
  const [query, setQuery] = useState("");
  const channels = useMemo(() => channelIds(conversations.values(), me), [conversations, me]);
  const items = useMemo<Item[]>(
    () => [
      ...[...conversations.values()]
        .sort((a, b) => b.updatedAt - a.updatedAt)
        .map((conversation) => ({ kind: "conversation" as const, id: `c:${conversation.id}`, conversation })),
      ...threads.map((thread) => ({ kind: "thread" as const, id: `t:${thread.root}`, thread })),
      ...actions.map((action) => ({ kind: "action" as const, id: `a:${action.id}`, action })),
    ],
    [conversations, threads, actions],
  );
  const entries = useMemo<PaletteRankEntry[]>(
    () =>
      items.map((item) =>
        item.kind === "conversation"
          ? {
              title: conversationName(item.conversation, me),
              keywords: item.conversation.participants.map((p) => p.name),
              isVisibleWhenQueryEmpty: true,
            }
          : item.kind === "thread"
            ? { title: item.thread.title, keywords: [t("thread.title")], isVisibleWhenQueryEmpty: false }
            : { title: item.action.title, keywords: [], isVisibleWhenQueryEmpty: true },
      ),
    [items, me, t],
  );
  const results = useMemo(() => {
    const ranked = rankPalette({ entries, query });
    return ranked.flatMap((section) => section.rows.map((row) => items[row.index]!)).slice(0, 60);
  }, [entries, items, query]);
  const byId = useMemo(() => new Map(results.map((item) => [item.id, item])), [results]);
  const run = (item: Item | undefined) => {
    if (!item) return;
    if (item.kind === "conversation") onPick(item.conversation.id);
    else if (item.kind === "thread") onPickThread(item.thread.root);
    else {
      onClose();
      item.action.run();
    }
  };
  // Tab would complete the field to an item id; the palette has nothing to complete.
  // Option-Up/Down move the list (useHomeKeys); they must not change the conversation behind the dialog.
  const onCommand = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Tab" || (event.altKey && (event.key === "ArrowUp" || event.key === "ArrowDown")))
      event.preventDefault();
  };
  const label = t("palette.placeholder");
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      label={t("rail.jump")}
      className="hc-switcher"
      backdropClassName="hc-scrim"
    >
      <div className="hc-switcher-field">
        <HomeIcon name="search" size={16} />
        <Combobox
          suggestions={results.map((item) => item.id)}
          onQuery={setQuery}
          onSubmit={(value) => run(byId.get(value) ?? results[0])}
          onCancel={onClose}
          label={label}
          placeholder={label}
          inline
          autoHighlight="always"
          cancelOnBlur={false}
          onCommand={onCommand}
          inputClassName="hc-switcher-input"
          listClassName="hc-switcher-list"
          itemClassName="hc-switcher-row"
          renderItem={(id) => {
            const item = byId.get(id);
            return item ? <Row item={item} channels={channels} me={me} strings={strings} /> : null;
          }}
        />
      </div>
      {results.length === 0 && <p className="hc-switcher-none">{t("switcher.none")}</p>}
      <p className="hc-switcher-hint" aria-hidden="true">
        {t("switcher.hint")}
      </p>
    </Dialog>
  );
}

function Row({
  item,
  channels,
  me,
  strings,
}: {
  item: Item;
  channels: ReadonlySet<string>;
  me?: string;
  strings: Strings;
}): ReactNode {
  const { t } = strings;
  if (item.kind === "conversation") {
    const c = item.conversation;
    const channel = channels.has(c.id);
    return (
      <>
        <ConversationAvatar conversation={c} channel={channel} me={me} size={22} />
        <span className={`hc-switcher-name${c.unread > 0 ? " unread" : ""}`}>
          {channel ? `# ${conversationName(c, me)}` : conversationName(c, me)}
        </span>
        <span className="hc-switcher-kind">{t(channel ? "palette.channel" : "palette.direct")}</span>
      </>
    );
  }
  if (item.kind === "thread")
    return (
      <>
        <span className="hc-switcher-icon">
          <HomeIcon name={item.thread.status === "resolved" ? "check" : "reply"} size={15} />
        </span>
        <span className="hc-switcher-name">{item.thread.title}</span>
        <span className="hc-switcher-kind">{t("thread.title")}</span>
      </>
    );
  return (
    <>
      <span className="hc-switcher-icon">
        <HomeIcon name={item.action.icon} size={15} />
      </span>
      <span className="hc-switcher-name">{item.action.title}</span>
      {item.action.key && <kbd className="hc-switcher-kind">{item.action.key}</kbd>}
    </>
  );
}
