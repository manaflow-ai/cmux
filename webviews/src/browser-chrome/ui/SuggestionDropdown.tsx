// The omnibar's suggestion card: the web twin of the native OmniboxSuggestionPanel and
// SuggestionRowView. It continues the bar downward (the bar's own width and corners, flush under it,
// or above it when the toolbar sits at the bottom), with 28 pt rows whose icon and text line up with
// the bar's chip and text. Rows only report the pointer and clicks; the omnibox state machine picks
// the one highlighted row and owns the keys. Rows are keyed by position, so typing changes their text
// in place and never rebuilds the card; the card never scrolls (at most 15 rows). The list is the
// shared ui/Listbox with a controlled highlight, so the field keeps focus.
import { useRef, type CSSProperties, type MouseEvent } from "react";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { Listbox } from "../../ui/Listbox";
import { TOOLBAR_METRICS as M } from "./toolbarModel";
import "./browserChrome.css";

export type SuggestionKind = "navigate" | "search" | "history" | "bookmark" | "keyword" | "switchToTab" | "answer";

export type SuggestionRow = {
  kind: SuggestionKind;
  /** Page title or query. */
  title: string;
  /** Display URL or engine ("Google Search"); empty for none. */
  detail: string;
  /** The site icon of a history, bookmark or open-tab row, once loaded. */
  faviconUrl?: string;
};

export type SuggestionModifiers = { meta: boolean; shift: boolean; alt: boolean };

export type SuggestionCommand =
  | { type: "pick"; index: number; modifiers: SuggestionModifiers }
  /** The pointer is over row `index`, or left the rows (null). */
  | { type: "hover"; index: number | null };

/**
 * - `joined`: today's card, opaque and flush under the bar, one line per row.
 * - `floating`: a separate glass popup a few points under the bar, with its own shadow.
 * - `two-line`: the joined card with the title over the URL, for long titles.
 */
export type SuggestionLook = "joined" | "floating" | "two-line";

export type SuggestionDropdownProps = {
  suggestions: readonly SuggestionRow[];
  highlighted: number | null;
  onCommand: (command: SuggestionCommand) => void;
  look?: SuggestionLook;
  /** Above the bar: rounded at the top, rows read from the bar upward. */
  upward?: boolean;
  /** Row ids are `${idPrefix}-${index}`, for the field's aria-activedescendant. */
  idPrefix?: string;
  /** The list's accessible name (the field's placeholder or label). */
  label: string;
  /** The host's density: each row is the bar's height, the card has the bar's corner radius. */
  metrics?: { bar: number; cornerRadius: number; fontSize: number };
  /** The card's tallest height (px): the rows scroll within it (`cardBoundsStyle`). */
  maxHeight?: number | null;
};

/** A card kept to `maxHeight` scrolls its rows; none (or not a number) leaves it its full height. */
export function cardBoundsStyle(maxHeight: number | null | undefined): CSSProperties {
  if (maxHeight == null || !Number.isFinite(maxHeight) || maxHeight <= 0) return {};
  return { maxHeight: `${Math.floor(maxHeight)}px`, overflowY: "auto" };
}

export const MAX_SUGGESTIONS = 15;

const KIND_ICONS: Record<SuggestionKind, string> = {
  navigate: "browser",
  search: "search",
  history: "history",
  bookmark: "bookmark",
  keyword: "extension",
  switchToTab: "omnibar.switchtab",
  answer: "omnibar.answer",
};

/** Rows that name a known web page show its site icon; the typed address keeps its globe. */
function showsSiteIcon(row: SuggestionRow): boolean {
  return !!row.faviconUrl && (row.kind === "history" || row.kind === "bookmark" || row.kind === "switchToTab");
}

const standardStyle = {
  "--bc-row": `${M.bar}px`,
  "--bc-row-inset": "4px",
  "--bc-row-gap": "2px",
  "--bc-card-end": "4px",
  // Icon and text on the bar's chip and text columns, less the row's inset.
  "--bc-row-icon-start": `${M.chipLeading + (M.chip - 16) / 2 - 4}px`,
  "--bc-row-text-start": `${M.chipLeading + M.chip + M.textLeading - 4}px`,
  "--bc-trailing-padding": `${M.trailingPadding}px`,
} as CSSProperties;

/** The sizes for the host's density: rows of the bar's height, icon and text on its chip and text. */
function densityStyle(m: { bar: number; cornerRadius: number; fontSize: number }): CSSProperties {
  const chip = m.bar - 2 * M.chipLeading;
  return {
    ...standardStyle,
    "--bc-row": `${m.bar}px`,
    "--bc-row-icon-start": `${M.chipLeading + (chip - 16) / 2 - 4}px`,
    "--bc-row-text-start": `${M.chipLeading + chip + M.textLeading - 4}px`,
    "--ds-radius-popup": `${m.cornerRadius}px`,
    "--text-field": `${m.fontSize}px`,
  } as CSSProperties;
}

const modifiers = (event: MouseEvent): SuggestionModifiers => ({
  meta: event.metaKey,
  shift: event.shiftKey,
  alt: event.altKey,
});

type Slot = { row: SuggestionRow; index: number };

export function SuggestionDropdown({
  suggestions,
  highlighted,
  onCommand,
  look = "joined",
  upward = false,
  idPrefix = "omnibox-suggestion",
  label,
  metrics,
  maxHeight,
}: SuggestionDropdownProps) {
  const slots: Slot[] = suggestions.slice(0, MAX_SUGGESTIONS).map((row, index) => ({ row, index }));
  // The shared listbox opens a row on its press; the press's modifiers are read here first.
  const pressed = useRef<SuggestionModifiers>({ meta: false, shift: false, alt: false });
  return (
    <div
      className={look === "floating" ? "bc-suggestions ui-popup ui-glass" : "bc-suggestions"}
      data-look={look}
      data-upward={upward || undefined}
      style={{ ...(metrics ? densityStyle(metrics) : standardStyle), ...cardBoundsStyle(maxHeight) }}
      onPointerLeave={() => onCommand({ type: "hover", index: null })}
      onMouseDownCapture={(event) => {
        pressed.current = modifiers(event);
      }}
      onWheel={(event) => event.stopPropagation()}
    >
      <Listbox
        items={slots}
        // Position keys: the next keystroke's matches land in the same rows.
        getKey={(slot) => String(slot.index)}
        getItemId={(slot) => `${idPrefix}-${slot.index}`}
        textValue={(slot) => slot.row.title}
        label={label}
        autoFocus={false}
        activeIndex={highlighted ?? -1}
        onActiveIndexChange={(index) => onCommand({ type: "hover", index })}
        onOpen={(slot) => onCommand({ type: "pick", index: slot.index, modifiers: pressed.current })}
        className="bc-suggestion-list"
        rowClassName="bc-suggestion"
        itemAttributes={(slot) => ({ "data-row-id": `suggestion-${slot.index}` })}
        renderItem={({ row }) => (
          <>
            <span className="bc-suggestion-icon">
              {showsSiteIcon(row) ? (
                <img src={row.faviconUrl} alt="" width={16} height={16} draggable={false} />
              ) : (
                <Icon name={KIND_ICONS[row.kind]} size={16} row />
              )}
            </span>
            <span className="bc-suggestion-text">
              <span className="bc-suggestion-title">{row.title}</span>
              {row.detail && <span className="bc-suggestion-detail">{row.detail}</span>}
            </span>
          </>
        )}
      />
    </div>
  );
}
