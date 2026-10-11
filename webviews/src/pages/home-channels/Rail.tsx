// The left rail: Channels (groups and named rooms; always shown, with "Add channel" at the end)
// and Direct messages (the Chief first, then each agent and person). Unread rows are bold; mentions
// and direct-message unreads show a count. A direct message to an agent says what it is (Chief,
// Agent) unless its name already does; rows that share a name get a muted disambiguator. A section
// header folds its section; a folded section still shows the open and the unread rows.
import { useMemo, useState, type ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { HomeIcon } from "./icons";
import { conversationName, disambiguators, memberTag, railSections } from "./model";
import type { HomeConversation } from "./types";

export interface RailProps {
  conversations: ReadonlyMap<string, HomeConversation>;
  me?: string;
  selected?: string;
  strings: Strings;
  onSelect(id: string): void;
  onOpenSwitcher(): void;
  /** "Add channel": opens the page's create popover at this row. */
  onAddChannel?(anchor: Element): void;
}

export function Rail({ conversations, me, selected, strings, onSelect, onOpenSwitcher, onAddChannel }: RailProps) {
  const { channels, direct } = railSections(conversations.values(), me);
  const { t } = strings;
  const extra = useMemo(() => {
    const stamp = new Intl.DateTimeFormat(strings.language, {
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
    });
    return disambiguators(conversations.values(), me, (at) => stamp.format(at));
  }, [conversations, me, strings.language]);
  const [folded, setFolded] = useState<ReadonlySet<string>>(new Set());
  const fold = (section: string) =>
    setFolded((current) => {
      const next = new Set(current);
      if (!next.delete(section)) next.add(section);
      return next;
    });
  return (
    <nav className="hc-rail" aria-label={t("page.title")}>
      <header className="hc-rail-header">
        <span className="hc-rail-title">{t("page.title")}</span>
      </header>
      <button type="button" className="hc-jump" onClick={onOpenSwitcher}>
        <span>{t("rail.jump")}</span>
        <kbd>⌘K</kbd>
      </button>
      <div className="hc-rail-scroll">
        <Section
          title={t("rail.channels")}
          folded={folded.has("channels")}
          onFold={() => fold("channels")}
          rows={channels}
          me={me}
          selected={selected}
          strings={strings}
          extra={extra}
          channel
          onSelect={onSelect}
          always
          footer={
            onAddChannel && (
              <button
                type="button"
                className="hc-rail-row hc-rail-add"
                onClick={(event) => onAddChannel(event.currentTarget)}
              >
                <span className="hc-rail-add-icon" aria-hidden="true">
                  +
                </span>
                <span className="hc-rail-name">{t("rail.addChannel")}</span>
              </button>
            )
          }
        />
        <Section
          title={t("rail.direct")}
          folded={folded.has("direct")}
          onFold={() => fold("direct")}
          rows={direct}
          me={me}
          selected={selected}
          strings={strings}
          extra={extra}
          onSelect={onSelect}
        />
        {conversations.size === 0 && <p className="hc-rail-empty">{t("rail.empty")}</p>}
      </div>
    </nav>
  );
}

function Section({
  title,
  folded,
  onFold,
  rows,
  me,
  selected,
  strings,
  extra,
  channel = false,
  onSelect,
  always = false,
  footer,
}: {
  title: string;
  folded: boolean;
  onFold(): void;
  rows: HomeConversation[];
  me?: string;
  selected?: string;
  strings: Strings;
  extra: ReadonlyMap<string, string>;
  /** The Channels section (its rows show # and no member tag). */
  channel?: boolean;
  onSelect(id: string): void;
  /** Shown even with no rows (Channels, so the shape and "Add channel" are always there). */
  always?: boolean;
  footer?: ReactNode;
}) {
  if (rows.length === 0 && !always) return null;
  const shown = folded ? rows.filter((row) => row.id === selected || (row.unread > 0 && !row.muted)) : rows;
  return (
    <section className={`hc-rail-section${folded ? " folded" : ""}`}>
      <h2>
        <button type="button" className="hc-rail-fold" aria-expanded={!folded} onClick={onFold}>
          <span className="hc-rail-caret" aria-hidden="true">
            <HomeIcon name="chevronRight" size={14} />
          </span>
          {title}
        </button>
      </h2>
      <ul>
        {shown.map((row) => (
          <li key={row.id}>
            <RailRow
              row={row}
              me={me}
              active={row.id === selected}
              extra={extra.get(row.id)}
              channel={channel}
              strings={strings}
              onSelect={onSelect}
            />
          </li>
        ))}
        {footer && !folded && <li>{footer}</li>}
      </ul>
    </section>
  );
}

function RailRow({
  row,
  me,
  active,
  extra,
  channel,
  strings,
  onSelect,
}: {
  row: HomeConversation;
  me?: string;
  active: boolean;
  extra?: string;
  channel: boolean;
  strings: Strings;
  onSelect(id: string): void;
}) {
  const name = conversationName(row, me);
  const other = channel ? undefined : row.participants.find((p) => p.id !== me);
  const unread = row.unread > 0 && !row.muted;
  // Mentions count everywhere; in a direct message every unread message is for me.
  const badge = row.mentions > 0 ? row.mentions : !channel && unread ? row.unread : 0;
  const kind = memberTag(row, me, channel);
  const tag = kind ? strings.t(kind === "chief" ? "chief.badge" : "agent.badge") : undefined;
  const showTag = tag !== undefined && tag.toLowerCase() !== name.trim().toLowerCase();
  return (
    <button
      type="button"
      className={`hc-rail-row${active ? " active" : ""}${unread ? " unread" : ""}${row.muted ? " muted" : ""}`}
      aria-current={active ? "page" : undefined}
      onClick={() => onSelect(row.id)}
    >
      {channel ? (
        <span className="hc-hash" aria-hidden="true">
          #
        </span>
      ) : (
        <Avatar participant={other} size={16} />
      )}
      <span className="hc-rail-name">
        {name}
        {extra && <span className="hc-rail-extra"> {extra}</span>}
      </span>
      {showTag && <span className="hc-tag">{tag}</span>}
      {badge > 0 && (
        <span
          className="hc-badge"
          aria-label={strings.format(row.mentions > 0 ? "unread.mentions" : "unread.messages", String(badge))}
        >
          {badge}
        </span>
      )}
    </button>
  );
}
