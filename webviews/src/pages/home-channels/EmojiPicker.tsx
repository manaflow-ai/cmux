// The emoji popover of the composer and of a message's "Add reaction": a search field over the
// icon picker's bundled emoji table (Unicode + CLDR names, the same ranker), then a grid. The
// table loads on the first open (`loadEmoji`, from the button's own press), not with the page.
import { useMemo, useState, type KeyboardEvent } from "react";
import { decodeEmojiTable, type EmojiRecord, type EmojiTable, type RawEmojiTable } from "../../icon-picker/emojiData";
import { search } from "../../icon-picker/search";
import { KeyboardScope } from "../../ui/KeyboardScope";
import { Popover } from "../../ui/Popover";
import type { Strings } from "../shared/i18n";

const SHOWN = 120;
let table: Promise<EmojiTable> | undefined;

/** The decoded emoji table, loaded once per page. */
export function loadEmoji(): Promise<EmojiTable> {
  table ??= import("../../icon-picker/generated/emoji-data.json")
    .then((module) => decodeEmojiTable((module.default ?? module) as unknown as RawEmojiTable))
    .catch((error: unknown) => {
      // The next open tries again.
      table = undefined;
      throw error;
    });
  return table;
}

export interface EmojiPickerProps {
  anchor: Element | null;
  emoji?: EmojiTable;
  strings: Strings;
  onPick(emoji: string): void;
  onClose(): void;
}

export function EmojiPicker({ anchor, emoji, strings, onPick, onClose }: EmojiPickerProps) {
  const [query, setQuery] = useState("");
  const results = useMemo<EmojiRecord[]>(
    () => (emoji ? search(emoji.records, query, undefined, SHOWN) : []),
    [emoji, query],
  );
  const label = strings.t("emoji.title");
  // Return in the search picks the first result (not the Return that ends an IME composition).
  const searchKeys = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
    if (event.key === "Enter" && results[0]) {
      event.preventDefault();
      onPick(results[0].emoji);
    }
  };
  return (
    <Popover
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      anchor={anchor}
      side="top"
      label={label}
      className="hc-emoji"
      finalFocus={false}
    >
      <KeyboardScope className="hc-emoji-search-keys" handleKeyDown={searchKeys}>
        <input
          className="hc-emoji-search"
          type="search"
          value={query}
          placeholder={strings.t("emoji.search")}
          aria-label={strings.t("emoji.search")}
          onChange={(event) => setQuery(event.target.value)}
        />
      </KeyboardScope>
      <div className="hc-emoji-grid">
        {results.map((record) => (
          <button
            key={record.index}
            type="button"
            className="hc-emoji-cell"
            // tooltip-allow: the emoji's name; the cell shows only the emoji
            title={record.names.en}
            aria-label={record.names.en}
            onClick={() => onPick(record.emoji)}
          >
            {record.emoji}
          </button>
        ))}
        {emoji && results.length === 0 && <p className="hc-emoji-none">{strings.t("emoji.none")}</p>}
      </div>
    </Popover>
  );
}
