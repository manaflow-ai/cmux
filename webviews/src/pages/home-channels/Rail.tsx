// The left rail: Channels (group conversations) and Direct messages (the Chief first, then each
// agent and person). Unread rows are bold; mentions show a count. A section header folds its
// section; a folded section still shows the open and the unread rows. One button opens the switcher.
import { useState } from "react";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { HomeIcon } from "./icons";
import { conversationName, railSections } from "./model";
import type { HomeConversation } from "./types";

export interface RailProps {
  conversations: ReadonlyMap<string, HomeConversation>;
  me?: string;
  selected?: string;
  strings: Strings;
  onSelect(id: string): void;
  onOpenSwitcher(): void;
}

export function Rail({ conversations, me, selected, strings, onSelect, onOpenSwitcher }: RailProps) {
  const { channels, direct } = railSections(conversations.values());
  const { t } = strings;
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
        {conversations.size === 0 && <p className="hc-rail-empty">{t("rail.empty")}</p>}
        <Section
          title={t("rail.channels")}
          folded={folded.has("channels")}
          onFold={() => fold("channels")}
          rows={channels}
          me={me}
          selected={selected}
          strings={strings}
          onSelect={onSelect}
        />
        <Section
          title={t("rail.direct")}
          folded={folded.has("direct")}
          onFold={() => fold("direct")}
          rows={direct}
          me={me}
          selected={selected}
          strings={strings}
          onSelect={onSelect}
        />
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
  onSelect,
}: {
  title: string;
  folded: boolean;
  onFold(): void;
  rows: HomeConversation[];
  me?: string;
  selected?: string;
  strings: Strings;
  onSelect(id: string): void;
}) {
  if (rows.length === 0) return null;
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
            <RailRow row={row} me={me} active={row.id === selected} strings={strings} onSelect={onSelect} />
          </li>
        ))}
      </ul>
    </section>
  );
}

function RailRow({
  row,
  me,
  active,
  strings,
  onSelect,
}: {
  row: HomeConversation;
  me?: string;
  active: boolean;
  strings: Strings;
  onSelect(id: string): void;
}) {
  const name = conversationName(row, me);
  const other = row.kind === "group" ? undefined : row.participants.find((p) => p.id !== me);
  const unread = row.unread > 0 && !row.muted;
  // Mentions count everywhere; in a direct message every unread message is for me.
  const badge = row.mentions > 0 ? row.mentions : row.kind !== "group" && unread ? row.unread : 0;
  return (
    <button
      type="button"
      className={`hc-rail-row${active ? " active" : ""}${unread ? " unread" : ""}${row.muted ? " muted" : ""}`}
      aria-current={active ? "page" : undefined}
      onClick={() => onSelect(row.id)}
    >
      {row.kind === "group" ? (
        <span className="hc-hash" aria-hidden="true">
          #
        </span>
      ) : (
        <Avatar participant={other} size={16} />
      )}
      <span className="hc-rail-name">{name}</span>
      {row.kind === "chief" && <span className="hc-tag">{strings.t("chief.badge")}</span>}
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
