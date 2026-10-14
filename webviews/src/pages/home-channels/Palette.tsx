// The Cmd-K palette: actions on what is open, the open conversation's threads, and every
// conversation, ranked by the command palette's own ranker (rankPalette). The shared primitives own
// the keyboard, roles and focus (ui/Dialog, ui/Combobox). With an empty query the actions come
// first, then the open threads, then recent conversations; typing ranks all of them together.
import { useMemo, useState, type KeyboardEvent, type ReactNode } from "react";
import { rankPalette, type PaletteRankEntry } from "../../palette/ranker";
import { Combobox } from "../../ui/Combobox";
import { Dialog } from "../../ui/Dialog";
import type { Strings } from "../shared/i18n";
import { HomeIcon, type HomeIconName } from "./icons";

export interface PaletteItem {
  id: string;
  section: "action" | "thread" | "conversation";
  title: string;
  keywords?: string[];
  /** Muted text after the title (where a thread lives, a shortcut). */
  detail?: string;
  icon: ReactNode | HomeIconName;
  run(): void;
}

export interface PaletteProps {
  items: readonly PaletteItem[];
  strings: Strings;
  onClose(): void;
}

const SECTION_ORDER = { action: 0, thread: 1, conversation: 2 } as const;

export function Palette({ items, strings, onClose }: PaletteProps) {
  const [query, setQuery] = useState("");
  const entries = useMemo<PaletteRankEntry[]>(
    () => items.map((item) => ({ title: item.title, keywords: item.keywords ?? [], isVisibleWhenQueryEmpty: true })),
    [items],
  );
  const results = useMemo(() => {
    const ranked = rankPalette({ entries, query }).flatMap((section) => section.rows.map((row) => items[row.index]!));
    const list = query.trim() ? ranked : [...ranked].sort((a, b) => SECTION_ORDER[a.section] - SECTION_ORDER[b.section]);
    return list.slice(0, 60);
  }, [entries, items, query]);
  const byId = useMemo(() => new Map(results.map((item) => [item.id, item])), [results]);
  const submit = (value: string) => {
    const found = byId.get(value) ?? results[0];
    if (!found) return;
    onClose();
    found.run();
  };
  const onCommand = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Tab" || (event.altKey && (event.key === "ArrowUp" || event.key === "ArrowDown")))
      event.preventDefault();
  };
  const label = strings.t("palette.placeholder");
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      label={strings.t("palette.title")}
      className="hc-switcher hc-palette"
      backdropClassName="hc-scrim"
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
        inputClassName="hc-switcher-input"
        listClassName="hc-switcher-list"
        itemClassName="hc-switcher-row"
        renderItem={(id) => {
          const item = byId.get(id);
          if (!item) return null;
          return (
            <>
              <span className={`hc-palette-icon ${item.section}`}>
                {typeof item.icon === "string" ? <HomeIcon name={item.icon as HomeIconName} size={16} /> : item.icon}
              </span>
              <span className="hc-rail-name">{item.title}</span>
              {item.detail && <span className="hc-palette-detail">{item.detail}</span>}
            </>
          );
        }}
      />
      {results.length === 0 && <p className="hc-switcher-none">{strings.t("switcher.none")}</p>}
      <p className="hc-switcher-hint" aria-hidden="true">
        {strings.t("palette.hint")}
      </p>
    </Dialog>
  );
}
