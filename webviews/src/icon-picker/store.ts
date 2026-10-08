// The icon picker's state owner: view (grid, image, SVG), category filter, query, active cell,
// skin tone, symbol rendering mode and recents. One grid holds emoji and SF Symbols: All
// Categories is Frequently Used, the emoji groups, then the symbols; the category menu narrows it
// to one emoji group, the symbols (by system category) or one symbol category. Every intent
// recomputes the grid synchronously (search + layout cost a few ms for the full tables; the cells
// are built once per catalog and tone), so one keystroke is one store change and one React commit
// of the visible rows only. React reads it with useSyncExternalStore; tests drive it directly.
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

/** The session's first view: the current icon's kind (the host's `tab`). */
export type PickerTab = IconKind;
/** What the picker shows: the icon grid, or the image or SVG sheet. */
export type PickerView = "grid" | "image" | "svg";

/** Category filter ids besides the emoji group ids and `symbolCategory.<key>`. */
export const ALL_CATEGORIES = "all";
export const RECENT_CATEGORY = "recent";
export const SYMBOLS_CATEGORY = "sfSymbols";
const SYMBOL_CATEGORY_PREFIX = "symbolCategory.";
const OTHER_SYMBOLS = `${SYMBOL_CATEGORY_PREFIX}other`;

export interface PickerCell {
  readonly key: string;
  readonly value: IconValue;
  /** The localized name (bottom bar and accessibility label). */
  readonly label: string;
  /** The detail: `:shortcode:` for an emoji. */
  readonly detail?: string;
  readonly emoji?: string;
  readonly symbol?: string;
  /** The symbol has a multicolor variant (the system's multicolor category). */
  readonly multicolor?: boolean;
}

/** One entry of the All Categories menu. */
export interface CategoryOption {
  readonly id: string;
  readonly label: string;
  /** How many icons the category holds. */
  readonly count: number;
  readonly kind: "all" | "recent" | "emoji" | "symbols" | "symbol";
  /** The emoji that stands for an emoji group. */
  readonly glyph?: string;
  /** The SF Symbol that stands for a symbol category. */
  readonly symbol?: string;
}

export interface PickerSnapshot {
  readonly view: PickerView;
  /** The category filter: an id of `categories`. */
  readonly category: string;
  readonly query: string;
  readonly tone: SkinTone;
  readonly layout: GridLayout<PickerCell>;
  /** How symbols are drawn. */
  readonly symbolMode: SymbolMode;
  /** The All Categories menu, in order. */
  readonly categories: readonly CategoryOption[];
  /** The grid shows emoji (the skin tone control applies). */
  readonly showsEmoji: boolean;
  /** The grid shows symbols (the rendering mode control applies). */
  readonly showsSymbols: boolean;
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
  /**
   * Localized titles by id: "all", "recent", "sfSymbols", "allSymbols", "results.emoji",
   * "results.sfSymbols", emoji group ids and `symbolCategory.<key>`.
   */
  readonly titles: (id: string) => string;
  readonly now?: () => number;
}

/** The glyph for each emoji group in the category menu (Unicode emoji-test group ids). */
const GROUP_GLYPHS: Readonly<Record<string, string>> = {
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

/** The grid's columns: as many tiles of at least MIN_PITCH as fit, at most MAX_COLUMNS. */
export const MAX_COLUMNS = 8;
export const MIN_PITCH = 52;
/** The row pitch before the first measure (a 600 pt panel). */
export const DEFAULT_CELL = 72;
export const HEADER_SIZE = 34;

type State = Pick<PickerSnapshot, "view" | "category" | "query" | "tone" | "active" | "reveal">;

export class PickerStore {
  private snapshot: PickerSnapshot;
  private readonly listeners = new Set<() => void>();
  private emoji: readonly EmojiRecord[] = [];
  /** Emoji key -> position in `emoji`. */
  private readonly emojiPos = new Map<string, number>();
  private emojiCells?: { tone: SkinTone; cells: readonly PickerCell[] };
  private symbols: readonly SymbolItem[] = [];
  private symbolCells: readonly PickerCell[] = [];
  private symbolByName = new Map<string, number>();
  /** Shown system categories, in the system's order. */
  private symbolCategories: readonly SymbolCategory[] = [];
  /** Indices of names in no shown category (the last section). */
  private uncategorized: readonly number[] = [];
  private memberSets = new Map<string, ReadonlySet<number>>();
  private prefs: PickerPrefs = EMPTY_PREFS;
  private prefsVersion = 0;
  private columns = MAX_COLUMNS;
  private cell = DEFAULT_CELL;
  private cache?: { key: string; layout: GridLayout<PickerCell>; categories: readonly CategoryOption[] };

  constructor(private readonly options: PickerStoreOptions) {
    this.load(options.symbols ?? [], options.maxEmojiVersion);
    this.snapshot = this.compute({ view: "grid", category: ALL_CATEGORIES, query: "", tone: 0, active: 0, reveal: 0 });
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
    this.emojiPos.clear();
    this.emoji.forEach((record, position) => this.emojiPos.set(`emoji:${record.emoji}`, position));
    this.emojiCells = undefined;
    const catalog = asCatalog(symbols);
    const count = catalog.names.length;
    this.symbols = symbolItems(catalog.names, catalog.keywords);
    this.symbolByName = new Map(this.symbols.map((item) => [item.name, item.index]));
    const valid = (members: readonly number[]) => members.filter((index) => index >= 0 && index < count);
    const categories = catalog.categories ?? [];
    const multicolor = new Set(
      valid(categories.find((category) => category.key === MULTICOLOR_CATEGORY)?.members ?? []),
    );
    this.symbolCells = this.symbols.map((item) => symbolCell(item.name, multicolor.has(item.index)));
    this.symbolCategories = categories
      .filter((category) => !HIDDEN_SYMBOL_CATEGORIES.has(category.key))
      .map((category) => ({ ...category, members: valid(category.members) }))
      .filter((category) => category.members.length > 0);
    const placed = new Set(this.symbolCategories.flatMap((category) => category.members));
    this.uncategorized = this.symbolCategories.length
      ? [...Array(count).keys()].filter((index) => !placed.has(index))
      : [];
    this.memberSets.clear();
  }

  /** A new picker session in a reused (prewarmed) page: empty query, All Categories (or the current icon's kind). */
  reset(tab: PickerTab = "emoji") {
    const view: PickerView = tab === "image" || tab === "svg" ? tab : "grid";
    const category = tab === "symbol" ? SYMBOLS_CATEGORY : ALL_CATEGORIES;
    this.update({ view, category, query: "", active: 0 });
  }

  setView(view: PickerView) {
    if (view !== this.snapshot.view) this.update({ view, active: 0 });
  }

  /** Shows one category in the grid (All Categories when `id` is unknown). */
  setCategory(id: string) {
    const category = this.snapshot.categories.some((option) => option.id === id) ? id : ALL_CATEGORIES;
    if (category !== this.snapshot.category || this.snapshot.view !== "grid")
      this.update({ view: "grid", category, active: 0 });
  }

  /** The next or previous category in the menu's order (Ctrl-Tab). */
  stepCategory(step: 1 | -1) {
    const { categories, category } = this.snapshot;
    const at = categories.findIndex((option) => option.id === category);
    const next = categories[(Math.max(0, at) + step + categories.length) % categories.length];
    if (next) this.setCategory(next.id);
  }

  /**
   * Escape and the back button: clears the search, else returns to All Categories; false when
   * there is nothing to step back from (the picker closes).
   */
  back(): boolean {
    const { query, view, category } = this.snapshot;
    if (query) this.update({ query: "", active: 0 });
    else if (view !== "grid" || category !== ALL_CATEGORIES)
      this.update({ view: "grid", category: ALL_CATEGORIES, active: 0 });
    else return false;
    return true;
  }

  setQuery(query: string) {
    if (query !== this.snapshot.query) this.update({ query, active: 0 });
  }

  /** The grid's usable width: columns and the square tile pitch follow it. */
  setWidth(width: number) {
    const columns = Math.min(MAX_COLUMNS, Math.max(1, Math.floor(width / MIN_PITCH)));
    const cell = Math.max(MIN_PITCH, Math.floor(width / columns));
    if (columns === this.columns && cell === this.cell) return;
    this.columns = columns;
    this.cell = cell;
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

  /** Records the use (Frequently Used) and returns the value to apply. */
  pick(cell: PickerCell): IconValue {
    const position = this.emojiPos.get(cell.key);
    // Recents keep the base emoji; the tone applies when it shows.
    const key = position === undefined ? cell.key : `emoji:${this.emoji[position].emoji}`;
    this.prefs = recordUse(this.prefs, key, this.now());
    this.prefsVersion++;
    this.options.prefs?.save(this.prefs);
    this.update({});
    return cell.value;
  }

  /** Records a copy of the cell (Cmd-C, Copy in the Actions menu) as a use, without finishing. */
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

  private update(change: Partial<State>) {
    this.snapshot = this.compute({ ...this.snapshot, ...change });
    for (const listener of this.listeners) listener();
  }

  private compute(state: State): PickerSnapshot {
    // Moving the active cell reuses the grid; only category, query, tone, width or recents rebuild it.
    const key = [state.category, state.query, state.tone, this.columns, this.cell, this.prefsVersion].join("\u0000");
    if (this.cache?.key !== key) {
      const layout = layoutGrid(this.sections(state), this.columns, { cell: this.cell, header: HEADER_SIZE });
      this.cache = { key, layout, categories: this.categoryOptions() };
    }
    const { layout, categories } = this.cache;
    const active = layout.items.length === 0 ? -1 : Math.min(Math.max(0, state.active), layout.items.length - 1);
    const grid = state.view === "grid";
    return {
      view: state.view,
      category: state.category,
      query: state.query,
      tone: state.tone,
      active,
      reveal: state.reveal,
      layout,
      categories,
      showsEmoji: grid && this.emojiPool(state.category) !== null,
      showsSymbols: grid && this.symbolPool(state.category) !== null,
      symbolMode: this.prefs.symbolMode ?? "monochrome",
    };
  }

  private categoryOptions(): CategoryOption[] {
    const title = this.options.titles;
    const recents = this.recentCount();
    const options: CategoryOption[] = [
      {
        id: ALL_CATEGORIES,
        label: title(ALL_CATEGORIES),
        count: this.emoji.length + this.symbols.length,
        kind: "all",
      },
    ];
    if (recents > 0)
      options.push({ id: RECENT_CATEGORY, label: title(RECENT_CATEGORY), count: recents, kind: "recent" });
    const counts = new Map<string, number>();
    for (const record of this.emoji) counts.set(record.group, (counts.get(record.group) ?? 0) + 1);
    for (const group of this.options.emoji.groups) {
      const count = counts.get(group) ?? 0;
      if (count === 0) continue;
      // A group a newer table adds shows its first emoji.
      const glyph = GROUP_GLYPHS[group] ?? this.emoji.find((record) => record.group === group)?.emoji;
      options.push({ id: group, label: title(group), count, kind: "emoji", glyph });
    }
    if (this.symbols.length === 0) return options;
    options.push({ id: SYMBOLS_CATEGORY, label: title(SYMBOLS_CATEGORY), count: this.symbols.length, kind: "symbols" });
    for (const category of this.symbolCategories) {
      const id = `${SYMBOL_CATEGORY_PREFIX}${category.key}`;
      options.push({ id, label: title(id), count: category.members.length, kind: "symbol", symbol: category.icon });
    }
    if (this.uncategorized.length > 0)
      options.push({
        id: OTHER_SYMBOLS,
        label: title(OTHER_SYMBOLS),
        count: this.uncategorized.length,
        kind: "symbol",
        symbol: "ellipsis.circle",
      });
    return options;
  }

  private emojiCellsFor(tone: SkinTone): readonly PickerCell[] {
    if (this.emojiCells?.tone !== tone) {
      const ja = this.options.language === "ja";
      const cells = this.emoji.map((record): PickerCell => {
        const emoji = withTone(record, tone);
        const code = record.shortcodes[0];
        const label = ja ? record.names.ja : record.names.en;
        return { key: `emoji:${record.emoji}`, value: { emoji }, label, detail: code ? `:${code}:` : undefined, emoji };
      });
      this.emojiCells = { tone, cells };
    }
    return this.emojiCells.cells;
  }

  /** How many Frequently Used icons have a cell. */
  private recentCount(): number {
    return this.prefs.recents.filter((entry) => this.emojiPos.has(entry.key) || entry.key.startsWith("symbol:")).length;
  }

  /** Frequently Used, best first: emoji and symbols (images and SVGs have no cell). */
  private recentCells(tone: SkinTone, limit: number): PickerCell[] {
    const emoji = this.emojiCellsFor(tone);
    const cells: PickerCell[] = [];
    for (const key of rankedKeys(this.prefs, this.now())) {
      if (cells.length >= limit) break;
      const position = this.emojiPos.get(key);
      if (position !== undefined) cells.push(emoji[position]);
      else if (key.startsWith("symbol:")) {
        const name = key.slice("symbol:".length);
        const index = this.symbolByName.get(name);
        // A symbol picked on another system that this catalog lacks still shows by name.
        cells.push(index === undefined ? symbolCell(name, false) : this.symbolCells[index]);
      }
    }
    return cells;
  }

  /** The emoji a category shows: every emoji, one group's (its id), or null for none. */
  private emojiPool(category: string): string | null {
    if (category === ALL_CATEGORIES || category === RECENT_CATEGORY) return "every";
    return this.options.emoji.groups.includes(category as never) ? category : null;
  }

  /** The symbols a category shows: every symbol, one category's members, or null for none. */
  private symbolPool(category: string): "every" | ReadonlySet<number> | null {
    if (this.symbols.length === 0) return category === RECENT_CATEGORY ? "every" : null;
    if (category === ALL_CATEGORIES || category === RECENT_CATEGORY || category === SYMBOLS_CATEGORY) return "every";
    if (!category.startsWith(SYMBOL_CATEGORY_PREFIX)) return null;
    let members = this.memberSets.get(category);
    if (!members) {
      const key = category.slice(SYMBOL_CATEGORY_PREFIX.length);
      const list =
        category === OTHER_SYMBOLS
          ? this.uncategorized
          : (this.symbolCategories.find((entry) => entry.key === key)?.members ?? []);
      members = new Set(list);
      this.memberSets.set(category, members);
    }
    return members;
  }

  private sections(state: State): GridSection<PickerCell>[] {
    const { category, tone } = state;
    const query = state.query.trim();
    const title = this.options.titles;
    const emoji = this.emojiCellsFor(tone);
    if (query) return this.resultSections(category, query, tone);
    if (category === RECENT_CATEGORY)
      return [{ id: RECENT_CATEGORY, title: title(RECENT_CATEGORY), items: this.recentCells(tone, Infinity) }];
    const sections: GridSection<PickerCell>[] = [];
    if (category === ALL_CATEGORIES)
      sections.push({
        id: RECENT_CATEGORY,
        title: title(RECENT_CATEGORY),
        items: this.recentCells(tone, this.columns * 2),
      });
    const groups = this.options.emoji.groups.filter((group) => category === ALL_CATEGORIES || group === category);
    if (groups.length > 0) {
      const byGroup = new Map<string, PickerCell[]>();
      this.emoji.forEach((record, position) => {
        let cells = byGroup.get(record.group);
        if (!cells) byGroup.set(record.group, (cells = []));
        cells.push(emoji[position]);
      });
      for (const group of groups) sections.push({ id: group, title: title(group), items: byGroup.get(group) ?? [] });
    }
    if (category === ALL_CATEGORIES) {
      sections.push({ id: SYMBOLS_CATEGORY, title: title(SYMBOLS_CATEGORY), items: this.symbolCells });
    } else if (category === SYMBOLS_CATEGORY) {
      if (this.symbolCategories.length === 0)
        sections.push({ id: "allSymbols", title: title("allSymbols"), items: this.symbolCells });
      for (const entry of this.symbolCategories) {
        const id = `${SYMBOL_CATEGORY_PREFIX}${entry.key}`;
        sections.push({ id, title: title(id), items: entry.members.map((index) => this.symbolCells[index]) });
      }
      if (this.symbolCategories.length > 0)
        sections.push({
          id: OTHER_SYMBOLS,
          title: title(OTHER_SYMBOLS),
          items: this.uncategorized.map((index) => this.symbolCells[index]),
        });
    } else if (category.startsWith(SYMBOL_CATEGORY_PREFIX)) {
      const pool = this.symbolPool(category);
      const members = pool instanceof Set ? [...pool].sort((a, b) => a - b) : [];
      sections.push({ id: category, title: title(category), items: members.map((index) => this.symbolCells[index]) });
    }
    return sections;
  }

  /** Search results: an Emoji section and a Symbols section, each ranked, within the category. */
  private resultSections(category: string, query: string, tone: SkinTone): GridSection<PickerCell>[] {
    const title = this.options.titles;
    const now = this.now();
    const recentOnly = category === RECENT_CATEGORY ? new Set(rankedKeys(this.prefs, now)) : null;
    const sections: GridSection<PickerCell>[] = [];
    const emojiPool = this.emojiPool(category);
    if (emojiPool !== null) {
      const emoji = this.emojiCellsFor(tone);
      const boost = searchBoost(
        this.prefs,
        (key) => {
          const position = this.emojiPos.get(key);
          return position === undefined ? undefined : this.emoji[position].index;
        },
        now,
      );
      const hits = search(this.emoji, query, boost).filter(
        (record) =>
          (emojiPool === "every" || record.group === emojiPool) &&
          (!recentOnly || recentOnly.has(`emoji:${record.emoji}`)),
      );
      const items = hits.map((record) => emoji[this.emojiPos.get(`emoji:${record.emoji}`)!]);
      sections.push({ id: "results.emoji", title: title("results.emoji"), items });
    }
    const symbolPool = this.symbolPool(category);
    if (symbolPool !== null && this.symbols.length > 0) {
      const hits = (search(this.symbols as readonly Searchable[], query) as SymbolItem[]).filter(
        (item) =>
          (symbolPool === "every" || symbolPool.has(item.index)) &&
          (!recentOnly || recentOnly.has(`symbol:${item.name}`)),
      );
      sections.push({
        id: "results.sfSymbols",
        title: title("results.sfSymbols"),
        items: hits.map((item) => this.symbolCells[item.index]),
      });
    }
    return sections;
  }
}

function symbolCell(name: string, multicolor: boolean): PickerCell {
  return { key: `symbol:${name}`, value: { symbol: name }, label: name, symbol: name, multicolor };
}
