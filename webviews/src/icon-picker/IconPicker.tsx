// The one icon picker (plans/cmux-next/icons.md): tabs Emoji, Symbols, Image, SVG; search by name,
// CLDR keywords and aliases in English and Japanese; recents first; remembered skin tone; a
// virtualized grid; keyboard driven from the search field. Hosts: the icon picker page (a native
// popover around a prewarmed web view) and any React page that embeds the component directly.
import { useState, useSyncExternalStore, type ClipboardEvent, type KeyboardEvent } from "react";
import type { Strings } from "../pages/shared/i18n";
import { AssetTab, type IconAssetSink } from "./AssetTab";
import type { SkinTone } from "./emojiData";
import type { IconValue } from "./iconValue";
import { JumpBar } from "./JumpBar";
import { pickerKeyAction } from "./keyboard";
import { CELL_SIZE, PickerStore, type PickerCell, type PickerTab } from "./store";
import { GridViewport, VirtualGrid } from "./VirtualGrid";

export const PICKER_TABS: readonly PickerTab[] = ["emoji", "symbol", "image", "svg"];
const TONE_SAMPLES = ["✋", "✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"];
const GRID_PADDING = 8;

export interface IconPickerProps {
  store: PickerStore;
  strings: Strings;
  onPick: (value: IconValue) => void;
  onCancel: () => void;
  /** Clears the icon; the Remove button shows only when given. */
  onClear?: () => void;
  assets?: IconAssetSink;
  /** The host's URL for a rendered SF Symbol (template image; the page tints it). */
  symbolImageURL?: (name: string) => string;
  /** Why the last pick did not apply (the host refused it); shown until the next session. */
  error?: string;
}

export function IconPicker({
  store,
  strings,
  onPick,
  onCancel,
  onClear,
  assets,
  symbolImageURL,
  error,
}: IconPickerProps) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [viewport] = useState(() => {
    const view = new GridViewport(CELL_SIZE);
    view.onWidth = (width) => store.setColumns((width - GRID_PADDING * 2) / CELL_SIZE);
    return view;
  });
  const [toneOpen, setToneOpen] = useState(false);
  const { t } = strings;
  const gridTab = snap.tab === "emoji" || snap.tab === "symbol";
  const active = snap.layout.items[snap.active];

  const pick = (cell: PickerCell | undefined) => {
    if (cell) onPick(store.pick(cell));
  };
  const jump = (top: number | null) => {
    if (top !== null) viewport.scrollTo(top);
  };
  const symbolMask = (name: string) => (symbolImageURL ? { maskImage: `url("${symbolImageURL(name)}")` } : undefined);
  const switchTab = (tab: PickerTab) => {
    store.setTab(tab);
    viewport.scrollToTop();
  };
  // Cmd-C (the app's Copy command reaches the page as a copy event) copies the selected emoji or
  // symbol name when no search text is selected.
  const onCopy = (event: ClipboardEvent<HTMLInputElement>) => {
    const field = event.currentTarget;
    if (field.selectionStart !== field.selectionEnd) return;
    const cell = store.activeCell();
    if (!cell || !gridTab) return;
    event.preventDefault();
    event.clipboardData.setData("text/plain", cell.emoji ?? cell.symbol ?? "");
    store.copied(cell);
  };
  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    const action = pickerKeyAction(event.nativeEvent);
    if (!action) return;
    if (!gridTab && action.kind !== "cancel" && action.kind !== "tab") return;
    event.preventDefault();
    switch (action.kind) {
      case "move":
        store.move(action.move, 6);
        viewport.reveal(store.getSnapshot().layout, store.getSnapshot().active);
        return;
      case "pick":
        return pick(store.activeCell() ?? undefined);
      case "cancel":
        return toneOpen ? setToneOpen(false) : onCancel();
      case "section":
        return jump(store.jumpBy(action.step));
      case "tab": {
        const next = (PICKER_TABS.indexOf(snap.tab) + action.step + PICKER_TABS.length) % PICKER_TABS.length;
        return switchTab(PICKER_TABS[next]);
      }
    }
  };
  const chooseTone = (tone: SkinTone) => {
    store.setTone(tone);
    setToneOpen(false);
  };

  return (
    <div className="icon-picker" aria-label={t("iconPicker.title")}>
      <div className="icon-picker-tabs" role="tablist" aria-label={t("iconPicker.tabs")}>
        {PICKER_TABS.map((tab) => (
          <button
            key={tab}
            type="button"
            role="tab"
            aria-selected={tab === snap.tab}
            className="icon-picker-tab"
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => switchTab(tab)}
            onKeyDown={onKeyDown}
          >
            {t(`iconPicker.tab.${tab}`)}
          </button>
        ))}
        {onClear && (
          <button type="button" className="icon-picker-clear" onClick={onClear}>
            {t("iconPicker.remove")}
          </button>
        )}
      </div>
      {error && (
        <p className="icon-picker-error" role="alert">
          {error}
        </p>
      )}
      {gridTab ? (
        <>
          <div className="icon-picker-search-row">
            <input
              className="icon-picker-search"
              type="search"
              value={snap.query}
              placeholder={t(snap.tab === "emoji" ? "iconPicker.search.emoji" : "iconPicker.search.symbols")}
              aria-label={t("iconPicker.search")}
              aria-controls="icon-grid"
              aria-activedescendant={active ? `icon-grid-cell-${snap.active}` : undefined}
              autoComplete="off"
              spellCheck={false}
              onKeyDown={onKeyDown}
              onCopy={onCopy}
              onChange={(event) => {
                store.setQuery(event.target.value);
                viewport.scrollToTop();
              }}
            />
            {snap.tab === "emoji" && (
              <div className="icon-tone">
                <button
                  type="button"
                  className="icon-tone-button"
                  aria-label={t("iconPicker.skinTone")}
                  aria-expanded={toneOpen}
                  onMouseDown={(event) => event.preventDefault()}
                  onClick={() => setToneOpen(!toneOpen)}
                >
                  {TONE_SAMPLES[snap.tone]}
                </button>
                {toneOpen && (
                  <div className="icon-tone-menu" aria-label={t("iconPicker.skinTone")}>
                    {TONE_SAMPLES.map((sample, tone) => (
                      <button
                        key={sample}
                        type="button"
                        aria-pressed={tone === snap.tone}
                        aria-label={t(`iconPicker.tone.${tone}`)}
                        onMouseDown={(event) => event.preventDefault()}
                        onClick={() => chooseTone(tone as SkinTone)}
                      >
                        {sample}
                      </button>
                    ))}
                  </div>
                )}
              </div>
            )}
          </div>
          {snap.jumps.length > 0 && (
            <JumpBar
              jumps={snap.jumps}
              layout={snap.layout}
              viewport={viewport}
              label={t("iconPicker.categories")}
              onJump={(id) => jump(store.jump(id))}
              symbolStyle={symbolMask}
            />
          )}
          <VirtualGrid
            layout={snap.layout}
            viewport={viewport}
            containerRef={viewport.attach}
            active={snap.active}
            id="icon-grid"
            label={t(`iconPicker.tab.${snap.tab}`)}
            onPick={(index) => pick(snap.layout.items[index])}
            onHover={(index) => store.setActive(index)}
            empty={t(snap.tab === "emoji" ? "iconPicker.empty.emoji" : "iconPicker.empty.symbols")}
            renderCell={(cell) =>
              cell.emoji ? (
                <span className="icon-emoji" aria-label={cell.label}>
                  {cell.emoji}
                </span>
              ) : (
                <span
                  className="icon-symbol"
                  aria-label={cell.label}
                  style={
                    symbolImageURL && cell.symbol ? { maskImage: `url("${symbolImageURL(cell.symbol)}")` } : undefined
                  }
                />
              )
            }
          />
          <div className="icon-picker-footer" aria-live="polite">
            {active && (
              <>
                {active.emoji ? (
                  <span className="icon-footer-glyph">{active.emoji}</span>
                ) : (
                  <span
                    className="icon-symbol icon-footer-symbol"
                    style={
                      symbolImageURL && active.symbol
                        ? { maskImage: `url("${symbolImageURL(active.symbol)}")` }
                        : undefined
                    }
                  />
                )}
                <span className="icon-footer-text">
                  <span className="icon-footer-name">{active.label}</span>
                  {active.detail && <span className="icon-footer-detail">{active.detail}</span>}
                </span>
              </>
            )}
          </div>
        </>
      ) : (
        <AssetTab
          kind={snap.tab === "svg" ? "svg" : "image"}
          sink={assets}
          strings={strings}
          onKeyDown={onKeyDown}
          onPicked={(value) => {
            store.recordAsset(value);
            onPick(value);
          }}
        />
      )}
    </div>
  );
}
