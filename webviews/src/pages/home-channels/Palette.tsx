// The Cmd-K palette: the center of navigation. One field over three groups: conversations (every
// room and person, newest first when the field is empty), the open conversation's threads (title,
// status, reply count) and actions on what is open (new channel, resolve the thread, assign it,
// copy a link, next unread). The daemon ranks the rows with the shared palette ranker
// (`cmux.home.paletteRank`, the daemon's `palette.rank`), so fuzzy and acronym rules match the app
// palette. Each keystroke asks once; the list keeps the last answer until the next one arrives (no
// empty frame between them), and an answer for an older query or older rows is dropped. The first
// frame shows the rows in their order, which is the ranker's answer for the empty query. Enter
// while the current query's answer is on its way waits for it and runs its top row, so it never
// runs a row from an older query's list. The shared primitives own the keyboard, roles and
// focus: ui/Dialog traps focus and returns it; ui/Combobox owns the combobox and listbox roles,
// the arrows and the highlighted row. A group's name shows over its first row (not read out: each
// row's own label says what it is).
import { useEffect, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { Combobox } from "../../ui/Combobox";
import { Dialog } from "../../ui/Dialog";
import type { Strings } from "../shared/i18n";
import { fixtureRank, type PaletteRankEntry, type PaletteRankReply, type PaletteRankRequest } from "./paletteRank";

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

/** The ranked rows, each group in its fixed place and cut to LIMIT. */
function grouped(items: readonly PaletteItem[], reply: PaletteRankReply): PaletteItem[] {
  const order = reply.sections.flatMap((section) =>
    section.rows.flatMap((row) => (items[row.index] ? [items[row.index]!] : [])),
  );
  return GROUPS.flatMap((group) => order.filter((item) => item.group === group).slice(0, LIMIT));
}

export function Palette({
  items,
  rank,
  strings,
  onClose,
}: {
  items: readonly PaletteItem[];
  /** Ranks the rows (the store's `rankPalette`: the daemon, or the fixture ranker offline). */
  rank(request: PaletteRankRequest): Promise<PaletteRankReply>;
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
  // Ranked within each group, groups in a fixed order. Until the first answer: the rows in order.
  // Kept as ids and read from the current rows, so a row that changed while an answer was on its
  // way runs its current action, and a row that left is not shown. `query` is the query they answer
  // and `ask` the request that answered it (0: none yet); `asked` counts the requests sent, so the
  // list answers the field as it is now only when `ranked.ask === asked.current`.
  const asked = useRef(0);
  const [ranked, setRanked] = useState<{ query: string; ask: number; ids: readonly string[] }>(() => ({
    query: "",
    ask: 0,
    ids: grouped(items, fixtureRank({ entries, query: "", keepsSectionOrder: true })).map((item) => item.id),
  }));
  const results = useMemo(() => {
    const rows = new Map(items.map((item) => [item.id, item]));
    return ranked.ids.flatMap((id) => rows.get(id) ?? []);
  }, [items, ranked]);
  // Enter came before the current query's answer: the query it was pressed for, whose answer's top
  // row runs when it lands. An edit to the field before then cancels it.
  const submitWhenRanked = useRef<string | null>(null);
  // The submission now on its way came from Enter (set by onCommand in the same keydown), not from a
  // click or tap on a row, which always runs the row it names.
  const enterSubmits = useRef(false);
  useEffect(() => {
    // Each query or set of rows asks once; the effect's cleanup drops an answer that comes after
    // the next ask (an older query's) or after the palette closed.
    let current = true;
    asked.current += 1;
    const ask = asked.current;
    const request = { entries, query, keepsSectionOrder: true };
    // A failed rank (the daemon went away) falls back to the substring filter, never to no rows.
    void rank(request)
      .catch(() => fixtureRank(request))
      .then((reply) => {
        if (current) setRanked({ query, ask, ids: grouped(items, reply).map((item) => item.id) });
      });
    return () => {
      current = false;
    };
  }, [entries, items, query, rank]);
  useEffect(() => {
    const pending = submitWhenRanked.current;
    if (pending === null) return;
    if (pending !== query) {
      submitWhenRanked.current = null;
      return;
    }
    // Wait for the newest request's answer: an older answer for the same text (typed away and back,
    // or rows that changed while it was being ranked again) is not the one Enter asked for.
    if (ranked.ask !== asked.current) return;
    submitWhenRanked.current = null;
    const top = results[0];
    if (!top) return;
    onClose();
    top.run();
  }, [onClose, query, ranked, results]);
  const byId = useMemo(() => new Map(results.map((item) => [item.id, item])), [results]);
  const firsts = useMemo(() => {
    const seen = new Set<PaletteGroup>();
    return new Set(results.filter((item) => !seen.has(item.group) && seen.add(item.group)).map((item) => item.id));
  }, [results]);
  const submit = (value: string) => {
    const fromEnter = enterSubmits.current;
    enterSubmits.current = false;
    // Enter while the list on screen answers an older request: its rows may not be what the field
    // now asks for, so wait for the newest request's answer. A clicked row runs itself; it is on screen.
    if (fromEnter && ranked.ask !== asked.current) {
      submitWhenRanked.current = query;
      return;
    }
    const item = byId.get(value) ?? (fromEnter ? results[0] : undefined);
    if (!item) return;
    onClose();
    item.run();
  };
  // Tab would complete the field to an item id; the palette has nothing to complete.
  // Option-Up/Down move the list (useHomeKeys); they must not change the conversation behind it.
  const onCommand = (event: KeyboardEvent<HTMLInputElement>) => {
    enterSubmits.current = event.key === "Enter" && !event.metaKey && !event.ctrlKey && !event.altKey;
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
