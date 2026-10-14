// The Cmd-K palette: the center of navigation. One field over three groups: conversations (every
// room and person, newest first when the field is empty), the open conversation's threads (title,
// status, reply count) and actions on what is open (new channel, resolve the thread, copy a link,
// next unread). Rows are ranked by the command palette's own ranker (rankPalette), so fuzzy and
// acronym rules match the app palette. ui/Dialog traps focus and returns it; the field owns the
// arrows, Return and Escape; the list is a listbox with the active row on aria-activedescendant.
import { useId, useMemo, useState, type KeyboardEvent, type ReactNode } from "react";
import { rankPalette, type PaletteRankEntry } from "../../palette/ranker";
import { Dialog } from "../../ui/Dialog";
import type { Strings } from "../shared/i18n";

export type PaletteGroup = "conversations" | "threads" | "actions";

export interface PaletteItem {
  id: string;
  group: PaletteGroup;
  title: string;
  /** Muted text after the title (the last activity, a thread's status and count). */
  meta?: string;
  keywords?: string[];
  mark?: ReactNode;
  /** The key that does the same outside the palette ("E", "⌥↓"). */
  shortcut?: string;
  run(): void;
}

const GROUPS: readonly PaletteGroup[] = ["conversations", "threads", "actions"];
const LIMIT = 40;

export function Palette({
  items,
  strings,
  onClose,
}: {
  items: readonly PaletteItem[];
  strings: Strings;
  onClose(): void;
}) {
  const { t } = strings;
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const listId = useId();
  const entries = useMemo<PaletteRankEntry[]>(
    () =>
      items.map((item) => ({
        title: item.title,
        keywords: item.keywords,
        sectionIndex: GROUPS.indexOf(item.group),
        isVisibleWhenQueryEmpty: true,
      })),
    [items],
  );
  const groups = useMemo(() => {
    const ranked = rankPalette({ entries, query, keepsSectionOrder: true });
    const order = ranked.flatMap((section) => section.rows.map((row) => items[row.index]!));
    return GROUPS.map((group) => ({ group, rows: order.filter((item) => item.group === group).slice(0, LIMIT) })).filter(
      (entry) => entry.rows.length > 0,
    );
  }, [entries, items, query]);
  const flat = groups.flatMap((entry) => entry.rows);
  const current = Math.min(active, Math.max(flat.length - 1, 0));
  const pick = (item: PaletteItem | undefined) => {
    if (!item) return;
    onClose();
    item.run();
  };
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "ArrowDown" || (event.key === "n" && event.ctrlKey)) {
      event.preventDefault();
      setActive((current + 1) % Math.max(flat.length, 1));
    } else if (event.key === "ArrowUp" || (event.key === "p" && event.ctrlKey)) {
      event.preventDefault();
      setActive((current - 1 + flat.length) % Math.max(flat.length, 1));
    } else if (event.key === "Enter") {
      event.preventDefault();
      pick(flat[current]);
    } else if (event.key === "Tab") {
      event.preventDefault();
    }
  };
  const label = t("palette.placeholder");
  let index = -1;
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      label={label}
      className="lg-palette"
      backdropClassName="lg-scrim"
    >
      <input
        className="lg-palette-input"
        role="combobox"
        aria-expanded="true"
        aria-controls={listId}
        aria-activedescendant={flat.length > 0 ? `${listId}-${current}` : undefined}
        aria-label={label}
        placeholder={label}
        value={query}
        spellCheck={false}
        onChange={(event) => {
          setQuery(event.target.value);
          setActive(0);
        }}
        onKeyDown={onKeyDown}
      />
      <div className="lg-palette-list" role="listbox" id={listId} aria-label={label}>
        {groups.map((entry) => (
          <div key={entry.group} role="group" aria-label={t(`palette.${entry.group}`)} className="lg-palette-group">
            <div className="lg-palette-heading" aria-hidden="true">
              {t(`palette.${entry.group}`)}
            </div>
            {entry.rows.map((item) => {
              index += 1;
              const mine = index;
              return (
                <div
                  key={item.id}
                  id={`${listId}-${mine}`}
                  role="option"
                  aria-selected={mine === current}
                  className={`lg-palette-row${mine === current ? " active" : ""}`}
                  onPointerMove={() => setActive(mine)}
                  onClick={() => pick(item)}
                >
                  <span className="lg-palette-mark">{item.mark}</span>
                  <span className="lg-palette-title">{item.title}</span>
                  {item.meta && <span className="lg-palette-meta">{item.meta}</span>}
                  {item.shortcut && <kbd className="lg-kbd">{item.shortcut}</kbd>}
                </div>
              );
            })}
          </div>
        ))}
        {flat.length === 0 && <p className="lg-palette-none">{t("switcher.none")}</p>}
      </div>
      <p className="lg-palette-hint" aria-hidden="true">
        {t("switcher.hint")}
      </p>
    </Dialog>
  );
}
