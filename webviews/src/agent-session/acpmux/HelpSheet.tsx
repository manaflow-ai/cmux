import { useContext, useLayoutEffect, useMemo, useRef, useState } from "react";
import { HELP_SECTIONS, helpRows, searchHelp, type HelpRow } from "./composerHelp";
import { focusRoute } from "../../ui/focusRoute";
import { useT } from "./i18n";
import { ShortcutsContext } from "./shortcuts";
import { KeyHint } from "../../ui/KeyHint";
import { Listbox } from "../../ui/Listbox";
import type { SlashCommand } from "./slashCommands";

/**
 * `/help` (composerHelp.ts): the composer's commands, skills and keys in one searchable list, drawn
 * where the `/` list draws (ComposerListLayer: above the box, its corners and glass) and in its row
 * type, with a quiet label over each group. Typing searches; the arrows move; Return on a command
 * writes `/name ` into the prompt; Escape closes and gives the prompt the keyboard back. A key row
 * only says its key.
 */
export function HelpSheet({
  commands,
  onInsert,
  onClose,
}: {
  commands: readonly SlashCommand[] | undefined;
  onInsert(command: SlashCommand): void;
  onClose(): void;
}) {
  const t = useT();
  const shortcuts = useContext(ShortcutsContext);
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const search = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const all = useMemo(() => helpRows(commands, shortcuts, t), [commands, shortcuts, t]);
  const rows = useMemo(() => searchHelp(all, query), [all, query]);
  const at = Math.min(active, Math.max(0, rows.length - 1));
  useLayoutEffect(() => void focusRoute(search.current, "person", "/help opened: its search"), []);

  const pick = (row: HelpRow | undefined): void => {
    if (row?.kind === "command") onInsert(row.command);
  };
  const onKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.nativeEvent.isComposing) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (!rows.length) return;
      const step = event.key === "ArrowDown" ? 1 : -1;
      setActive((at + step + rows.length) % rows.length);
    } else if (event.key === "Enter") {
      event.preventDefault();
      pick(rows[at]);
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      onClose();
    }
  };

  // Each group's label sits, unread, at the top of its first row: the list is the shared Listbox
  // (one row type, its keyboard and active-descendant contract), and the label is decoration.
  const firstOf = new Set(HELP_SECTIONS.map((section) => rows.find((row) => row.section === section.id)?.id));
  const labelOf = (row: HelpRow) => HELP_SECTIONS.find((section) => section.id === row.section)?.label;
  return (
    <div
      className="ui-popup ui-glass acpmux-slash-menu acpmux-help-sheet"
      data-cmux-component="HelpSheet"
      // host-glass-allow: drawn in the `/` list's place and material (SlashMenu, on the web_floating backlog); they move to host glass together.
    >
      <input
        ref={search}
        className="acpmux-help-search"
        type="search"
        aria-controls="acpmux-help-list"
        aria-activedescendant={rows.length ? `acpmux-help-${at}` : undefined}
        aria-label={t("help.search")}
        placeholder={t("help.search")}
        value={query}
        onChange={(event) => {
          setQuery(event.target.value);
          setActive(0);
        }}
        onKeyDown={onKeyDown}
        onBlur={(event) => {
          // A click on a row keeps the sheet; focus leaving the sheet closes it.
          const next = event.relatedTarget as Node | null;
          if (!next || !event.currentTarget.parentElement?.contains(next)) onClose();
        }}
      />
      <Listbox
        listRef={list}
        items={rows as readonly HelpRow[]}
        getKey={(row) => row.id}
        textValue={(row) => row.title}
        label={t("help.title")}
        autoFocus={false}
        activeIndex={at}
        onActiveIndexChange={setActive}
        onOpen={(row: HelpRow) => pick(row)}
        getItemId={(_, index) => `acpmux-help-${index}`}
        id="acpmux-help-list"
        className="acpmux-help-list"
        rowClassName="acpmux-slash-row acpmux-help-row"
        itemAttributes={(row) => ({ "data-help-kind": row.kind })}
        empty={<div className="acpmux-slash-empty">{t("help.none")}</div>}
        renderItem={(row) => {
          const label = firstOf.has(row.id) ? labelOf(row) : undefined;
          return (
            <>
              {label && (
                <span className="acpmux-help-label" aria-hidden>
                  {t(label)}
                </span>
              )}
              <span className="acpmux-slash-name">{row.title}</span>
              {row.kind === "command" ? (
                <>
                  {row.hint && <span className="acpmux-slash-hint">{row.hint}</span>}
                  {row.detail && <span className="acpmux-slash-description">{row.detail}</span>}
                  {row.tag && <span className="acpmux-slash-source">{row.tag}</span>}
                </>
              ) : (
                <span className="acpmux-help-keys">
                  {row.keys.split(" ").map((key, n) => (
                    <KeyHint key={`${n}:${key}`} keys={key} />
                  ))}
                </span>
              )}
            </>
          );
        }}
      />
    </div>
  );
}
