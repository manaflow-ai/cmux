// The Cmd-K palette: the center of navigation. One field over three groups: conversations (every
// room and person, newest first when the field is empty), the open conversation's threads (title,
// status, reply count) and actions on what is open (new channel, resolve the thread, assign it,
// copy a link, next unread). Rows are ranked by the command palette's own ranker (rankPalette), so
// fuzzy and acronym rules match the app palette. The shared primitives own the keyboard, roles and
// focus: ui/Dialog traps focus and returns it; ui/Combobox owns the combobox and listbox roles,
// the arrows and the highlighted row. A group's name shows over its first row (not read out: each
// row's own label says what it is).
import { useMemo, useState, type KeyboardEvent, type ReactNode } from "react";
import { rankPalette, type PaletteRankEntry } from "../../palette/ranker";
import { Combobox } from "../../ui/Combobox";
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
  /** The key that does the same outside the palette ("E", "⌥⇧↓"). */
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
  // Ranked within each group, groups in a fixed order.
  const results = useMemo(() => {
    const ranked = rankPalette({ entries, query, keepsSectionOrder: true });
    const order = ranked.flatMap((section) => section.rows.map((row) => items[row.index]!));
    return GROUPS.flatMap((group) => order.filter((item) => item.group === group).slice(0, LIMIT));
  }, [entries, items, query]);
  const byId = useMemo(() => new Map(results.map((item) => [item.id, item])), [results]);
  const firsts = useMemo(() => {
    const seen = new Set<PaletteGroup>();
    return new Set(results.filter((item) => !seen.has(item.group) && seen.add(item.group)).map((item) => item.id));
  }, [results]);
  const submit = (value: string) => {
    const item = byId.get(value) ?? results[0];
    if (!item) return;
    onClose();
    item.run();
  };
  // Tab would complete the field to an item id; the palette has nothing to complete.
  // Option-Up/Down move the list (useHomeKeys); they must not change the conversation behind it.
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
      label={label}
      className="lg-palette"
      backdropClassName="lg-scrim"
    >
      <Combobox
        suggestions={results.map((item) => item.id)}
        onQuery={setQuery}
        onSubmit={submit}
        onCancel={onClose}
        label={label}
        placeholder={label}
        inline
        autoHighlight="always"
        cancelOnBlur={false}
        onCommand={onCommand}
        rootClassName="lg-palette-root"
        inputClassName="lg-palette-input"
        listClassName="lg-palette-list"
        itemClassName="lg-palette-row"
        renderItem={(id) => {
          const item = byId.get(id);
          if (!item) return null;
          return (
            <>
              {firsts.has(id) && (
                <span className="lg-palette-heading" aria-hidden="true">
                  {t(`palette.${item.group}`)}
                </span>
              )}
              <span className="lg-palette-line">
                <span className="lg-palette-mark">{item.mark}</span>
                <span className="lg-palette-title">{item.title}</span>
                {item.meta && <span className="lg-palette-meta">{item.meta}</span>}
                {item.shortcut && <kbd className="lg-kbd">{item.shortcut}</kbd>}
              </span>
            </>
          );
        }}
      />
      {results.length === 0 && <p className="lg-palette-none">{t("switcher.none")}</p>}
      <p className="lg-palette-hint" aria-hidden="true">
        {t("switcher.hint")}
      </p>
    </Dialog>
  );
}
