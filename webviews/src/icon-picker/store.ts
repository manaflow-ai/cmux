// The icon picker's state owner: tab, query, active cell, skin tone and recents. Every intent
// recomputes the grid synchronously (search + layout cost about 1 ms for the full emoji table),
// so one keystroke is one store change and one React commit of the visible rows only.
// React reads it with useSyncExternalStore; tests drive it directly.
import { withTone, type EmojiRecord, type EmojiTable, type SkinTone } from "./emojiData";
import { layoutGrid, moveActive, type GridLayout, type GridMove, type GridSection } from "./gridModel";
import { iconKey, type IconKind, type IconValue } from "./iconValue";
import { EMPTY_PREFS, rankedKeys, recordUse, searchBoost, type PickerPrefs, type PickerPrefsStore } from "./recents";
import { search, type Searchable } from "./search";
import {
  asCatalog,
  HIDDEN_SYMBOL_CATEGORIES,
  MULTICOLOR_CATEGORY,
  symbolItems,
  type SymbolCatalog,
  type SymbolCategory,
  type SymbolItem,
  type SymbolMode,
} from "./symbols";

export type PickerTab = IconKind;
export const GRID_TABS: readonly PickerTab[] = ["emoji", "symbol"];

export interface PickerCell {
  readonly key: string;
  readonly value: IconValue;
  /** The localized name (footer and accessibility label). */
  readonly label: string;
  /** The detail line: `:shortcode:` for an emoji, the symbol name for a symbol. */
  readonly detail?: string;
  readonly emoji?: string;
  readonly symbol?: string;
  /** The symbol has a multicolor variant (the system's multicolor category). */
  readonly multicolor?: boolean;
}

/** A category jump bar target: a titled section, drawn with an emoji or an SF Symbol. */
export interface JumpTarget {
  readonly id: string;
  readonly label: string;
  readonly glyph?: string;
  readonly symbol?: string;
}

export interface PickerSnapshot {
  readonly tab: PickerTab;
  readonly query: string;
  readonly tone: SkinTone;
  readonly layout: GridLayout<PickerCell>;
  /** How the Symbols tab draws symbols. */
  readonly symbolMode: SymbolMode;
  /** The jump bar's targets (none while searching). */
  readonly jumps: readonly JumpTarget[];
  /** Index into layout.items; -1 when nothing is active. */
  readonly active: number;
  /** Bumped when the active cell moves by keyboard, so the grid scrolls it into view. */
  readonly reveal: number;
}

export interface PickerStoreOptions {
  readonly emoji: EmojiTable;
  readonly symbols?: SymbolCatalog | readonly string[];
  readonly prefs?: PickerPrefsStore;
  /** Emoji newer than the system font draws (Emoji version times 10) are hidden. */
  readonly maxEmojiVersion?: number;
  readonly language?: string;
  /** Localized section titles by id ("recent", emoji group ids, "allSymbols"). */
  readonly titles: (id: string) => string;
  readonly now?: () => number;
}

/** The jump bar's glyph for each emoji group (Unicode emoji-test group ids). */
const GROUP_GLYPHS: Readonly<Record<string, string>> = {
  recent: "🕘",
  "smileys-emotion": "😀",
  "people-body": "👋",
  "animals-nature": "🐻",
  "food-drink": "🍔",
  "travel-places": "🚗",
  activities: "⚽",
  objects: "💡",
  symbols: "🔣",
  flags: "🏁",
};
/** The jump bar's SF Symbol for the Symbols tab's own sections. */
const SECTION_SYMBOLS: Readonly<Record<string, string>> = {
  recent: "clock",
  allSymbols: "square.grid.2x2",
  "symbolCategory.other": "ellipsis.circle",
};

export const CELL_SIZE = 44;
export const HEADER_SIZE = 28;

export class PickerStore {
  private snapshot: PickerSnapshot;
  private readonly listeners = new Set<() => void>();
  private emoji: readonly EmojiRecord[] = [];
  private symbols: readonly SymbolItem[] = [];
  /** Shown system categories (sections), in the system's order. */
  private symbolCategories: readonly SymbolCategory[] = [];
  /** Section id -> the category's SF Symbol (jump bar). */
  private categoryIcons = new Map<string, string>();
  /** Indices of names in no shown category (the last section). */
  private uncategorized: readonly number[] = [];
  private multicolor: ReadonlySet<number> = new Set();
  private readonly emojiByKey = new Map<string, EmojiRecord>();
  private prefs: PickerPrefs = EMPTY_PREFS;
  private prefsVersion = 0;
  private columns = 9;
  private cache?: { key: string; layout: GridLayout<PickerCell>; jumps: readonly JumpTarget[] };

  constructor(private readonly options: PickerStoreOptions) {
    this.load(options.symbols ?? [], options.maxEmojiVersion);
    this.snapshot = this.compute({ tab: "emoji", query: "", tone: 0, active: 0, reveal: 0 });
    const loaded = options.prefs?.load();
    if (loaded instanceof Promise) void loaded.then((prefs) => this.applyPrefs(prefs));
    else if (loaded) this.applyPrefs(loaded);
  }

  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  readonly getSnapshot = () => this.snapshot;

  /** The host's catalog: SF Symbol names and the newest Emoji version the system font draws. */
  configure(symbols: SymbolCatalog | readonly string[], maxEmojiVersion?: number) {
    this.load(symbols, maxEmojiVersion);
    this.cache = undefined;
    this.update({});
  }

  private load(symbols: SymbolCatalog | readonly string[], maxEmojiVersion = Infinity) {
    this.emoji = this.options.emoji.records.filter((record) => record.version <= maxEmojiVersion);
    this.emojiByKey.clear();
    for (const record of this.emoji) this.emojiByKey.set(`emoji:${record.emoji}`, record);
    const catalog = asCatalog(symbols);
    const count = catalog.names.length;
    this.symbols = symbolItems(catalog.names, catalog.keywords);
    const valid = (members: readonly number[]) => members.filter((index) => index >= 0 && index < count);
    const categories = catalog.categories ?? [];
    this.multicolor = new Set(
      valid(categories.find((category) => category.key === MULTICOLOR_CATEGORY)?.members ?? []),
    );
    this.symbolCategories = categories
      .filter((category) => !HIDDEN_SYMBOL_CATEGORIES.has(category.key))
      .map((category) => ({ ...category, members: valid(category.members) }))
      .filter((category) => category.members.length > 0);
    this.categoryIcons = new Map(
      this.symbolCategories.map((category) => [`symbolCategory.${category.key}`, category.icon]),
    );
    const placed = new Set(this.symbolCategories.flatMap((category) => category.members));
    this.uncategorized = this.symbolCategories.length
      ? [...Array(count).keys()].filter((index) => !placed.has(index))
      : [];
  }

  /** A new picker session in a reused (prewarmed) page: empty query, first cell, chosen tab. */
  reset(tab: PickerTab = "emoji") {
    this.update({ tab, query: "", active: 0 });
  }

  setTab(tab: PickerTab) {
    if (tab !== this.snapshot.tab) this.update({ tab, active: 0 });
  }

  setQuery(query: string) {
    if (query !== this.snapshot.query) this.update({ query, active: 0 });
  }

  setColumns(columns: number) {
    const next = Math.max(1, Math.floor(columns));
    if (next === this.columns) return;
    this.columns = next;
    this.update({});
  }

  setTone(tone: SkinTone) {
    this.prefs = { ...this.prefs, tone };
    this.options.prefs?.save(this.prefs);
    this.update({ tone });
  }

  setActive(index: number) {
    if (index !== this.snapshot.active) this.update({ active: index });
  }

  move(move: GridMove, pageRows?: number) {
    const active = moveActive(this.snapshot.layout, this.snapshot.active, move, pageRows);
    this.update({ active, reveal: this.snapshot.reveal + 1 });
  }

  /** The active cell, or null when the grid is empty. */
  activeCell(): PickerCell | null {
    return this.snapshot.layout.items[this.snapshot.active] ?? null;
  }

  /** Records the use (recents) and returns the value to apply. */
  pick(cell: PickerCell): IconValue {
    const record = this.emojiByKey.get(cell.key);
    // Recents keep the base emoji; the tone applies when it shows.
    this.prefs = recordUse(this.prefs, record ? `emoji:${record.emoji}` : cell.key, this.now());
    this.prefsVersion++;
    this.options.prefs?.save(this.prefs);
    this.update({});
    return cell.value;
  }

  /** Records a copy of the cell (Cmd-C) as a use, without finishing the picker. */
  copied(cell: PickerCell) {
    this.pick(cell);
  }

  /** Records an image or SVG pick (they have no grid cell). */
  recordAsset(value: IconValue) {
    this.prefs = recordUse(this.prefs, iconKey(value), this.now());
    this.prefsVersion++;
    this.options.prefs?.save(this.prefs);
  }

  private now() {
    return (this.options.now ?? Date.now)();
  }

  private applyPrefs(prefs: PickerPrefs) {
    this.prefs = prefs;
    this.prefsVersion++;
    this.update({ tone: prefs.tone });
  }

  /** Activates section `id`'s first cell; returns its header offset (null when absent). */
  jump(id: string): number | null {
    const section = this.snapshot.layout.sections.find((anchor) => anchor.id === id);
    if (!section) return null;
    this.setActive(section.first);
    return section.top;
  }

  /** Jumps to the section `step` after (or before) the active cell's section. */
  jumpBy(step: 1 | -1): number | null {
    const { sections } = this.snapshot.layout;
    if (sections.length === 0) return null;
    let current = 0;
    for (let index = 0; index < sections.length; index++) {
      if (sections[index].first <= this.snapshot.active) current = index;
    }
    const target = sections[Math.min(sections.length - 1, Math.max(0, current + step))];
    return this.jump(target.id);
  }

  setSymbolMode(symbolMode: SymbolMode) {
    if (symbolMode === this.snapshot.symbolMode) return;
    this.prefs = { ...this.prefs, symbolMode };
    this.options.prefs?.save(this.prefs);
    this.update({});
  }

  private update(change: Partial<Omit<PickerSnapshot, "layout" | "jumps" | "symbolMode">>) {
    this.snapshot = this.compute({ ...this.snapshot, ...change });
    for (const listener of this.listeners) listener();
  }

  private compute(
    state: Omit<PickerSnapshot, "layout" | "jumps" | "symbolMode"> & { layout?: unknown },
  ): PickerSnapshot {
    // Moving the active cell reuses the grid; only tab, query, tone, width or recents rebuild it.
    const key = [state.tab, state.query, state.tone, this.columns, this.prefsVersion].join("\u0000");
    if (this.cache?.key !== key) {
      const sections =
        state.tab === "symbol" ? this.symbolSections(state.query) : this.emojiSections(state.query, state.tone);
      const layout = layoutGrid(sections, this.columns, { cell: CELL_SIZE, header: HEADER_SIZE });
      this.cache = { key, layout, jumps: this.jumpTargets(state.tab, layout) };
    }
    const { layout, jumps } = this.cache;
    const active = layout.items.length === 0 ? -1 : Math.min(Math.max(0, state.active), layout.items.length - 1);
    return {
      tab: state.tab,
      query: state.query,
      tone: state.tone,
      active,
      reveal: state.reveal,
      layout,
      jumps,
      symbolMode: this.prefs.symbolMode ?? "monochrome",
    };
  }

  /** One target per titled section; search results (an untitled section) have none. */
  private jumpTargets(tab: PickerTab, layout: GridLayout<PickerCell>): JumpTarget[] {
    return layout.sections.map(({ id, title, first }) => {
      if (tab === "symbol")
        return { id, label: title, symbol: this.categoryIcons.get(id) ?? SECTION_SYMBOLS[id] ?? "circle" };
      // A group a newer table adds shows its first emoji.
      return { id, label: title, glyph: GROUP_GLYPHS[id] ?? layout.items[first]?.emoji ?? "•" };
    });
  }

  private emojiCell(record: EmojiRecord, tone: SkinTone): PickerCell {
    const emoji = withTone(record, tone);
    const label = this.options.language === "ja" ? record.names.ja : record.names.en;
    const code = record.shortcodes[0];
    return { key: `emoji:${record.emoji}`, value: { emoji }, label, detail: code ? `:${code}:` : undefined, emoji };
  }

  private emojiSections(query: string, tone: SkinTone): GridSection<PickerCell>[] {
    const now = this.now();
    const title = this.options.titles;
    if (query.trim()) {
      const boost = searchBoost(this.prefs, (key) => this.emojiByKey.get(key)?.index, now);
      const hits = search(this.emoji, query, boost);
      return [{ id: "results", title: "", items: hits.map((record) => this.emojiCell(record, tone)) }];
    }
    const recent = rankedKeys(this.prefs, now)
      .map((key) => this.emojiByKey.get(key))
      .filter((record): record is EmojiRecord => !!record)
      .slice(0, this.columns * 2);
    const sections: GridSection<PickerCell>[] = [
      { id: "recent", title: title("recent"), items: recent.map((record) => this.emojiCell(record, tone)) },
    ];
    const byGroup = new Map<string, PickerCell[]>();
    for (const record of this.emoji) {
      let cells = byGroup.get(record.group);
      if (!cells) byGroup.set(record.group, (cells = []));
      cells.push(this.emojiCell(record, tone));
    }
    for (const group of this.options.emoji.groups) {
      sections.push({ id: group, title: title(group), items: byGroup.get(group) ?? [] });
    }
    return sections;
  }

  private symbolSections(query: string): GridSection<PickerCell>[] {
    const cell = (item: SymbolItem): PickerCell => ({
      key: `symbol:${item.name}`,
      value: { symbol: item.name },
      label: item.name,
      symbol: item.name,
      multicolor: this.multicolor.has(item.index),
    });
    const title = this.options.titles;
    if (query.trim()) {
      const hits = search(this.symbols as readonly Searchable[], query) as SymbolItem[];
      return [{ id: "results", title: "", items: hits.map(cell) }];
    }
    const byName = new Map(this.symbols.map((item) => [item.name, item]));
    const recent = rankedKeys(this.prefs, this.now())
      .filter((key) => key.startsWith("symbol:"))
      .slice(0, this.columns * 2)
      .map((key) => key.slice("symbol:".length))
      .map((name) => byName.get(name) ?? { index: -1, name, nameText: "", searchText: "" });
    const sections: GridSection<PickerCell>[] = [{ id: "recent", title: title("recent"), items: recent.map(cell) }];
    if (this.symbolCategories.length === 0) {
      sections.push({ id: "allSymbols", title: title("allSymbols"), items: this.symbols.map(cell) });
      return sections;
    }
    const at = (index: number) => cell(this.symbols[index]);
    for (const category of this.symbolCategories) {
      sections.push({
        id: `symbolCategory.${category.key}`,
        title: title(`symbolCategory.${category.key}`),
        items: category.members.map(at),
      });
    }
    sections.push({
      id: "symbolCategory.other",
      title: title("symbolCategory.other"),
      items: this.uncategorized.map(at),
    });
    return sections;
  }
}
