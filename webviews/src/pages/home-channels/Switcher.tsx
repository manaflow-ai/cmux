// The Cmd-K conversation switcher, ranked by the command palette's own ranker (rankPalette) so it
// matches the palette's fuzzy and acronym rules. Arrow keys move, Enter opens, Escape closes.
import { useMemo, useState } from "react";
import { rankPalette, type PaletteRankEntry } from "../../palette/ranker";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { conversationName } from "./model";
import type { HomeConversation } from "./types";

export interface SwitcherProps {
  conversations: ReadonlyMap<string, HomeConversation>;
  me?: string;
  strings: Strings;
  onPick(id: string): void;
  onClose(): void;
}

export function Switcher({ conversations, me, strings, onPick, onClose }: SwitcherProps) {
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const list = useMemo(() => [...conversations.values()].sort((a, b) => b.updatedAt - a.updatedAt), [conversations]);
  const entries = useMemo<PaletteRankEntry[]>(
    () =>
      list.map((c) => ({
        title: conversationName(c, me),
        keywords: c.participants.map((p) => p.name),
        isVisibleWhenQueryEmpty: true,
      })),
    [list, me],
  );
  const results = useMemo(() => {
    const ranked = rankPalette({ entries, query });
    return ranked.flatMap((section) => section.rows.map((row) => list[row.index]!)).slice(0, 50);
  }, [entries, list, query]);
  const pick = (index: number) => {
    const found = results[index];
    if (found) onPick(found.id);
  };
  const onKeyDown = (event: React.KeyboardEvent) => {
    if (event.key === "ArrowDown") setActive((value) => Math.min(value + 1, results.length - 1));
    else if (event.key === "ArrowUp") setActive((value) => Math.max(value - 1, 0));
    else if (event.key === "Enter") pick(active);
    else if (event.key === "Escape") onClose();
    else return;
    event.preventDefault();
  };
  return (
    <div className="hc-scrim" onMouseDown={onClose}>
      <div
        className="hc-switcher"
        role="dialog"
        aria-label={strings.t("rail.jump")}
        onMouseDown={(event) => event.stopPropagation()}
      >
        <input
          ref={(element) => element?.focus()}
          className="hc-switcher-input"
          placeholder={strings.t("switcher.placeholder")}
          value={query}
          onChange={(event) => {
            setQuery(event.target.value);
            setActive(0);
          }}
          onKeyDown={onKeyDown}
          aria-label={strings.t("switcher.placeholder")}
          aria-expanded="true"
          aria-controls="hc-switcher-list"
          aria-activedescendant={results[active] ? `hc-switch-${results[active].id}` : undefined}
        />
        <ul id="hc-switcher-list" role="listbox" className="hc-switcher-list">
          {results.length === 0 && <li className="hc-switcher-none">{strings.t("switcher.none")}</li>}
          {results.map((c, index) => (
            <li
              key={c.id}
              id={`hc-switch-${c.id}`}
              role="option"
              aria-selected={index === active}
              className={`hc-switcher-row${index === active ? " active" : ""}`}
              onMouseEnter={() => setActive(index)}
              onClick={() => pick(index)}
            >
              {c.kind === "group" ? (
                <span className="hc-hash">#</span>
              ) : (
                <Avatar participant={c.participants.find((p) => p.id !== me)} size={16} />
              )}
              <span className="hc-rail-name">{conversationName(c, me)}</span>
              {c.unread > 0 && <span className="hc-badge subtle">{c.unread}</span>}
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
