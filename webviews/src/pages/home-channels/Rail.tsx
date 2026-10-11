// The left rail: Channels (group conversations) and Direct messages (the Chief first, then each
// agent and person). Unread rows are bold; mentions show a count. One button opens the switcher.
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
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
          rows={channels}
          me={me}
          selected={selected}
          strings={strings}
          onSelect={onSelect}
        />
        <Section
          title={t("rail.direct")}
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
  rows,
  me,
  selected,
  strings,
  onSelect,
}: {
  title: string;
  rows: HomeConversation[];
  me?: string;
  selected?: string;
  strings: Strings;
  onSelect(id: string): void;
}) {
  if (rows.length === 0) return null;
  return (
    <section className="hc-rail-section">
      <h2>{title}</h2>
      <ul>
        {rows.map((row) => (
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
      {row.mentions > 0 && (
        <span className="hc-badge" aria-label={strings.format("unread.mentions", String(row.mentions))}>
          {row.mentions}
        </span>
      )}
    </button>
  );
}
