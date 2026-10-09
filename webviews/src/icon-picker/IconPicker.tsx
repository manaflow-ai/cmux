// The one icon picker (plans/cmux-next/icons.md), laid out like a launcher's emoji search: a back
// button and a large search field on top, with the skin tone, symbol rendering and All Categories
// menus beside it; one virtualized grid of large square tiles (Frequently Used, the emoji groups,
// then SF Symbols, each section with its count); a bottom bar with the selected icon's name, the
// primary action (Set Icon, Return) and the Actions menu (Cmd-K: copy, image, SVG, remove).
// Search covers emoji names, CLDR keywords and shortcodes (English and Japanese) and symbol names
// and keywords. Keyboard driven from the search field; typing anywhere searches. Hosts: the icon
// picker page (a native panel around a prewarmed web view) and any React page that embeds it.
import {
  useRef,
  useState,
  useSyncExternalStore,
  type ClipboardEvent,
  type CSSProperties,
  type KeyboardEvent,
  type RefObject,
} from "react";
import type { Strings } from "../pages/shared/i18n";
import {
  Menu,
  MenuButton,
  MenuItem,
  MenuPopup,
  MenuRadioGroup,
  MenuRadioItem,
  MenuSeparator,
  Submenu,
} from "../ui/Menu";
import { AssetTab, type IconAssetSink } from "./AssetTab";
import type { SkinTone } from "./emojiData";
import type { IconValue } from "./iconValue";
import { pickerKeyAction, typesText } from "./keyboard";
import { DEFAULT_CELL, PickerStore, type CategoryOption, type PickerCell, type PickerView } from "./store";
import { SYMBOL_MODES, symbolRendering, type SymbolMode } from "./symbols";
import { GridViewport, VirtualGrid } from "./VirtualGrid";

const TONE_SAMPLES = ["✋", "✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"];
/** The grid's side padding (styles.css .icon-grid-scroll). */
const GRID_PADDING = 12;
/** Rows a Page Up or Page Down moves. */
const PAGE_ROWS = 4;

export interface IconPickerProps {
  store: PickerStore;
  strings: Strings;
  onPick: (value: IconValue) => void;
  onCancel: () => void;
  /** Clears the icon; Remove Icon shows only when given. */
  onClear?: () => void;
  /** Writes text to the clipboard (Copy in the Actions menu); the item shows only when given. */
  onCopyText?: (text: string) => void;
  assets?: IconAssetSink;
  /**
   * The host's URL for a rendered SF Symbol: monochrome and hierarchical are template images the
   * page tints with its theme color (CSS mask); multicolor is a finished image.
   */
  symbolImageURL?: (name: string, mode: SymbolMode) => string;
  /** Why the last pick did not apply (the host refused it); shown until the next session. */
  error?: string;
}

export function IconPicker({
  store,
  strings,
  onPick,
  onCancel,
  onClear,
  onCopyText,
  assets,
  symbolImageURL,
  error,
}: IconPickerProps) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [viewport] = useState(() => {
    const view = new GridViewport(DEFAULT_CELL);
    view.onWidth = (width) => store.setWidth(width - GRID_PADDING * 2);
    return view;
  });
  const searchRef = useRef<HTMLInputElement>(null);
  // The open menu: skin tone, symbol rendering, category or actions (one at a time).
  const [menu, setMenu] = useState<"tone" | "mode" | "category" | "actions" | null>(null);
  const menuProps = (name: "tone" | "mode" | "category" | "actions") => ({
    open: menu === name,
    onOpenChange: (open: boolean) => setMenu(open ? name : menu === name ? null : menu),
  });
  const { t } = strings;
  const grid = snap.view === "grid";
  const active = grid ? snap.layout.items[snap.active] : undefined;
  const category = snap.categories.find((option) => option.id === snap.category) ?? snap.categories[0];

  const pick = (cell: PickerCell | undefined | null) => {
    if (cell) onPick(store.pick(cell));
  };
  const scrollTop = () => viewport.scrollToTop();
  const back = () => {
    if (store.back()) scrollTop();
    else onCancel();
  };
  const chooseCategory = (id: string) => {
    setMenu(null);
    store.setCategory(id);
    scrollTop();
  };
  const showView = (view: PickerView) => {
    store.setView(view);
    scrollTop();
  };
  /** A symbol's style: a mask in the theme color, except multicolor (the symbol's own colors). */
  const symbolStyle = (name: string, multicolor = false): CSSProperties | undefined => {
    if (!symbolImageURL) return undefined;
    const mode = symbolRendering(snap.symbolMode, multicolor);
    const url = `url("${symbolImageURL(name, mode)}")`;
    return mode === "multicolor" ? { backgroundImage: url, backgroundColor: "transparent" } : { maskImage: url };
  };
  /** Menu glyphs stay monochrome in every mode. */
  const symbolMask = (name: string) =>
    symbolImageURL ? { maskImage: `url("${symbolImageURL(name, "monochrome")}")` } : undefined;
  const copyText = (cell: PickerCell) => cell.emoji ?? cell.symbol ?? "";
  const copyActive = () => {
    const cell = store.activeCell();
    if (!cell || !onCopyText) return;
    onCopyText(copyText(cell));
    store.copied(cell);
  };
  // Cmd-C (the app's Copy command reaches the page as a copy event) copies the selected emoji or
  // symbol name when no search text is selected.
  const onCopy = (event: ClipboardEvent<HTMLInputElement>) => {
    const field = event.currentTarget;
    if (field.selectionStart !== field.selectionEnd) return;
    const cell = store.activeCell();
    if (!cell) return;
    event.preventDefault();
    event.clipboardData.setData("text/plain", copyText(cell));
    store.copied(cell);
  };
  // One key handler for the whole picker: keys from the search field drive the grid; keys from a
  // button or the image sheet keep their own meaning, except Escape, Cmd-K and category steps; a
  // typed character from outside a text field moves focus to the search, which then receives it.
  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    const target = event.target as HTMLElement;
    // Menus portal outside the picker's DOM but bubble through React: they own their keys.
    if (!event.currentTarget.contains(target)) return;
    const inSearch = target === searchRef.current;
    const inField = target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement;
    const action = pickerKeyAction(event.nativeEvent);
    if (!action) {
      if (grid && !inField && typesText(event.nativeEvent)) searchRef.current?.focus();
      return;
    }
    switch (action.kind) {
      case "back":
        event.preventDefault();
        return back();
      case "actions":
        event.preventDefault();
        return setMenu("actions");
      case "category":
        event.preventDefault();
        store.stepCategory(action.step);
        return scrollTop();
    }
    if (!grid || !inSearch) return;
    event.preventDefault();
    switch (action.kind) {
      case "move":
        store.move(action.move, PAGE_ROWS);
        viewport.reveal(store.getSnapshot().layout, store.getSnapshot().active);
        return;
      case "pick":
        return pick(store.activeCell());
      case "section": {
        const top = store.jumpBy(action.step);
        if (top !== null) viewport.scrollTo(top);
        return;
      }
    }
  };
  const placeholder = t(
    snap.showsEmoji && snap.showsSymbols
      ? "iconPicker.search.all"
      : snap.showsSymbols
        ? "iconPicker.search.symbols"
        : "iconPicker.search.emoji",
  );
  const empty = t(
    snap.showsEmoji && snap.showsSymbols
      ? "iconPicker.empty.all"
      : snap.showsSymbols
        ? "iconPicker.empty.symbols"
        : "iconPicker.empty.emoji",
  );

  return (
    <div className="icon-picker" aria-label={t("iconPicker.title")} onKeyDown={onKeyDown}>
      <div className="icon-picker-top">
        <button
          type="button"
          className="icon-picker-back"
          aria-label={t("iconPicker.back")}
          onMouseDown={(event) => event.preventDefault()}
          onClick={back}
        >
          <ChevronIcon direction="left" />
        </button>
        {grid ? (
          <input
            ref={searchRef}
            className="icon-picker-search"
            type="search"
            value={snap.query}
            placeholder={placeholder}
            aria-label={t("iconPicker.search")}
            aria-controls="icon-grid"
            aria-activedescendant={active ? `icon-grid-cell-${snap.active}` : undefined}
            autoComplete="off"
            spellCheck={false}
            onCopy={onCopy}
            onChange={(event) => {
              store.setQuery(event.target.value);
              scrollTop();
            }}
          />
        ) : (
          <h1 className="icon-picker-heading">{t(`iconPicker.tab.${snap.view}`)}</h1>
        )}
        {snap.showsEmoji && (
          <Menu {...menuProps("tone")}>
            <MenuButton className="icon-picker-control icon-tone-button" label={t("iconPicker.skinTone")}>
              {TONE_SAMPLES[snap.tone]}
            </MenuButton>
            <MenuPopup side="bottom" align="end" finalFocus={searchRef}>
              <MenuRadioGroup
                value={String(snap.tone)}
                onValueChange={(tone) => {
                  setMenu(null);
                  store.setTone(Number(tone) as SkinTone);
                }}
              >
                {TONE_SAMPLES.map((sample, tone) => (
                  <MenuRadioItem key={sample} value={String(tone)} className="icon-tone-item">
                    <span className="icon-menu-emoji">{sample}</span>
                    {t(`iconPicker.tone.${tone}`)}
                  </MenuRadioItem>
                ))}
              </MenuRadioGroup>
            </MenuPopup>
          </Menu>
        )}
        {snap.showsSymbols && symbolImageURL && (
          <Menu {...menuProps("mode")}>
            <MenuButton className="icon-picker-control icon-mode-button" label={t("iconPicker.symbolMode")}>
              <span className="icon-symbol icon-mode-symbol" style={symbolStyle("paintpalette", true)} />
            </MenuButton>
            <MenuPopup side="bottom" align="end" finalFocus={searchRef} className="icon-mode-menu">
              <MenuRadioGroup
                value={snap.symbolMode}
                onValueChange={(mode) => {
                  setMenu(null);
                  store.setSymbolMode(mode as SymbolMode);
                }}
              >
                {SYMBOL_MODES.map((mode) => (
                  <MenuRadioItem key={mode} value={mode}>
                    {t(`iconPicker.symbolMode.${mode}`)}
                  </MenuRadioItem>
                ))}
              </MenuRadioGroup>
            </MenuPopup>
          </Menu>
        )}
        {grid && category && (
          <CategoryMenu
            categories={snap.categories}
            current={category}
            strings={strings}
            symbolMask={symbolMask}
            finalFocus={searchRef}
            menu={menuProps("category")}
            onChoose={chooseCategory}
          />
        )}
      </div>
      {error && (
        <p className="icon-picker-error" role="alert">
          {error}
        </p>
      )}
      {grid ? (
        <VirtualGrid
          layout={snap.layout}
          viewport={viewport}
          containerRef={viewport.attach}
          active={snap.active}
          id="icon-grid"
          label={category?.label ?? t("iconPicker.title")}
          onPick={(index) => pick(snap.layout.items[index])}
          onHover={(index) => store.setActive(index)}
          empty={empty}
          renderCell={(cell) =>
            cell.emoji ? (
              <span className="icon-emoji" aria-label={cell.label}>
                {cell.emoji}
              </span>
            ) : (
              <span
                className="icon-symbol"
                aria-label={cell.label}
                style={cell.symbol ? symbolStyle(cell.symbol, cell.multicolor) : undefined}
              />
            )
          }
        />
      ) : (
        <AssetTab
          kind={snap.view === "svg" ? "svg" : "image"}
          sink={assets}
          strings={strings}
          onPicked={(value) => {
            store.recordAsset(value);
            onPick(value);
          }}
        />
      )}
      <div className="icon-picker-bar">
        <div className="icon-bar-pill icon-bar-item" aria-live="polite">
          {active ? (
            <>
              {active.emoji ? (
                <span className="icon-bar-glyph">{active.emoji}</span>
              ) : (
                <span
                  className="icon-symbol icon-bar-symbol"
                  style={active.symbol ? symbolStyle(active.symbol, active.multicolor) : undefined}
                />
              )}
              <span className="icon-bar-name">{active.label}</span>
              {active.detail && <span className="icon-bar-detail">{active.detail}</span>}
            </>
          ) : (
            <span className="icon-bar-name icon-bar-title">{t("iconPicker.title")}</span>
          )}
        </div>
        <div className="icon-bar-pill icon-bar-actions">
          {active && (
            <>
              <button
                type="button"
                className="icon-bar-button icon-bar-primary"
                onMouseDown={(event) => event.preventDefault()}
                onClick={() => pick(active)}
              >
                {t("iconPicker.setIcon")}
                <kbd className="icon-keycap">↩</kbd>
              </button>
              <span className="icon-bar-divider" aria-hidden />
            </>
          )}
          <Menu {...menuProps("actions")}>
            <MenuButton className="icon-bar-button icon-bar-actions-button">
              {t("iconPicker.actions")}
              <kbd className="icon-keycap">⌘</kbd>
              <kbd className="icon-keycap">K</kbd>
            </MenuButton>
            <MenuPopup side="top" align="end" finalFocus={searchRef} className="icon-actions-menu">
              <MenuItem disabled={!active} shortcut="↩" onSelect={() => pick(active)}>
                {t("iconPicker.setIcon")}
              </MenuItem>
              {onCopyText && (
                <MenuItem disabled={!active} shortcut="⌘C" onSelect={copyActive}>
                  {t(active?.symbol ? "iconPicker.copySymbol" : "iconPicker.copyEmoji")}
                </MenuItem>
              )}
              {assets && (
                <>
                  <MenuSeparator />
                  {!grid && <MenuItem onSelect={() => showView("grid")}>{t("iconPicker.showIcons")}</MenuItem>}
                  {snap.view !== "image" && (
                    <MenuItem onSelect={() => showView("image")}>{t("iconPicker.useImage")}</MenuItem>
                  )}
                  {snap.view !== "svg" && (
                    <MenuItem onSelect={() => showView("svg")}>{t("iconPicker.useSVG")}</MenuItem>
                  )}
                </>
              )}
              {onClear && (
                <>
                  <MenuSeparator />
                  <MenuItem className="ui-menu-item-destructive" onSelect={onClear}>
                    {t("iconPicker.remove")}
                  </MenuItem>
                </>
              )}
            </MenuPopup>
          </Menu>
        </div>
      </div>
    </div>
  );
}

/**
 * The All Categories menu: the current category's name on the button; All Categories, Frequently
 * Used, the emoji groups, SF Symbols and (in a submenu) the symbol categories, each with its count.
 */
function CategoryMenu({
  categories,
  current,
  strings,
  symbolMask,
  finalFocus,
  menu,
  onChoose,
}: {
  categories: readonly CategoryOption[];
  current: CategoryOption;
  strings: Strings;
  symbolMask: (name: string) => CSSProperties | undefined;
  finalFocus: RefObject<HTMLElement | null>;
  menu: { open: boolean; onOpenChange: (open: boolean) => void };
  onChoose: (id: string) => void;
}) {
  const { t } = strings;
  const top = categories.filter((option) => option.kind === "all" || option.kind === "recent");
  const emoji = categories.filter((option) => option.kind === "emoji");
  const symbols = categories.filter((option) => option.kind === "symbols");
  const symbolCategories = categories.filter((option) => option.kind === "symbol");
  const count = (option: CategoryOption) => option.count.toLocaleString(strings.language);
  const item = (option: CategoryOption) => (
    <MenuRadioItem key={option.id} value={option.id} shortcut={count(option)}>
      {option.glyph ? (
        <span className="icon-menu-emoji" aria-hidden>
          {option.glyph}
        </span>
      ) : option.symbol ? (
        <span className="icon-symbol icon-menu-symbol" aria-hidden style={symbolMask(option.symbol)} />
      ) : null}
      {option.label}
    </MenuRadioItem>
  );
  return (
    <Menu {...menu}>
      <MenuButton className="icon-picker-control icon-category-button" label={t("iconPicker.categories")}>
        <GridIcon />
        <span className="icon-category-label">{current.label}</span>
        <ChevronIcon direction="down" />
      </MenuButton>
      <MenuPopup side="bottom" align="end" finalFocus={finalFocus} className="icon-category-menu">
        <MenuRadioGroup value={current.id} onValueChange={onChoose}>
          {top.map(item)}
          {emoji.length > 0 && <MenuSeparator />}
          {emoji.map(item)}
          {symbols.length > 0 && <MenuSeparator />}
          {symbols.map(item)}
        </MenuRadioGroup>
        {symbolCategories.length > 0 && (
          <Submenu label={t("iconPicker.symbolCategories")} popupClassName="icon-category-menu">
            <MenuRadioGroup value={current.id} onValueChange={onChoose}>
              {symbolCategories.map(item)}
            </MenuRadioGroup>
          </Submenu>
        )}
      </MenuPopup>
    </Menu>
  );
}

/** Chrome glyphs drawn inline (no host image), so they render in every host and the gallery. */
function ChevronIcon({ direction }: { direction: "left" | "down" }) {
  const path = direction === "left" ? "M10 3 5 8l5 5" : "M3.5 6 8 10.5 12.5 6";
  return (
    <svg className={`icon-chevron icon-chevron-${direction}`} viewBox="0 0 16 16" aria-hidden>
      <path d={path} fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function GridIcon() {
  return (
    <svg className="icon-grid-glyph" viewBox="0 0 16 16" aria-hidden>
      <rect x="1.75" y="1.75" width="12.5" height="12.5" rx="3" fill="none" stroke="currentColor" strokeWidth="1.3" />
      {[5.5, 8, 10.5].flatMap((y) =>
        [5.5, 8, 10.5].map((x) => <circle key={`${x}:${y}`} cx={x} cy={y} r="0.85" fill="currentColor" />),
      )}
    </svg>
  );
}
