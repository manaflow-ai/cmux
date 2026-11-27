import React, { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { focusAfterEscape } from "../../ui/escapeFocus";
import { focusWithRing } from "../../ui/focusWithRing";
import { UI_ANCHOR_GAP, useUiAnchor } from "../../ui/anchor";
import { useEscapingPopup } from "../../ui/popupHost";
import { usePopupHost } from "../../ui/UiProvider";
import { usePopupSettle } from "../../ui/popupSettle";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import { isMousePress } from "../../ui/pressRelease";
import { useListKeys } from "../../ui/useListKeys";
import { registerPicker } from "./pickerOpeners";
import { KeyHint } from "../../ui/KeyHint";
import { hintIsKey } from "./composerPickerModel";

import { useT } from "./i18n";
import { scrollActiveMenuRow } from "./scrollActiveMenuRow";
import { useScrollEdges } from "./summary/scrollEdges";
import {
  type PaletteReturnLook,
  type PaletteSection,
  descriptionRestatesName,
  filterPaletteSections,
} from "./paletteMenuModel";
import { focusRoute } from "../../ui/focusRoute";
type Props = {
  label: string;
  className?: string;
  button: React.ReactNode;
  sections: PaletteSection[];
  align?: "start" | "end";
  returnFocus?: boolean;
  tooltip?: string;
  onOpen?: () => void;
  /** How the highlighted row says what Return does (paletteMenuModel `PaletteReturnLook`). Default "verb": the keycap and
   * the verb Return carries out (Leo, 2026-11-22). "none" is the look before. */
  returnLook?: PaletteReturnLook;
  /** The search field's placeholder and name; default "Search actions, chats and tabs" (`palette.searchPlaceholder`). */
  placeholder?: string;
  /** Leave out a description that only restates its row's title (`descriptionRestatesName`). Default on. */
  quietDescriptions?: boolean;
};

/** Searchable, keyboard navigable + menu. It dispatches every row through the native action registry. */
export function PaletteMenu({
  label,
  className = "",
  button,
  sections,
  align = "start",
  returnFocus = true,
  tooltip,
  onOpen,
  returnLook = "verb",
  placeholder,
  quietDescriptions = true,
}: Props) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [searchHeight, setSearchHeight] = useState<number>();
  const [active, setActive] = useState(0);
  const [error, setError] = useState<string>();
  const dispatch = useRef(0);
  const root = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement | null>(null);
  const search = useRef<HTMLInputElement>(null);
  const menuId = useId();
  // The list scrolls under the search field; its edges fade where rows pass under them.
  const edges = useScrollEdges();
  const host = usePopupHost();
  const [shown, setShown] = useState<HTMLDivElement | null>(null);
  const attachNode = useCallback(
    (node: HTMLDivElement | null) => {
      menu.current = node;
      if (host) setShown(node);
    },
    [host],
  );
  const attach = usePopupSettle<HTMLDivElement>(attachNode);
  const menuStyle = useUiAnchor(trigger, menu, open, { side: "above", align });
  useEscapingPopup(host, shown, () => trigger.current, {
    side: "top",
    align,
    gap: UI_ANCHOR_GAP,
    // Keep the searchable surface (input and section headers) in-page when it overflows;
    // exporting a list would hide those controls in popupHost.
    kind: "menu",
    active: ".acpmux-menu-active",
  });
  const filtered = useMemo(() => filterPaletteSections(sections, query), [query, sections]);
  const rows = useMemo(
    () => filtered.flatMap((section) => section.choices.map((choice) => ({ section, choice }))),
    [filtered],
  );
  const selected = Math.min(active, Math.max(rows.length - 1, 0));
  const searchLabel = placeholder ?? t("palette.searchPlaceholder");
  // The outcome line under the list (the `footer` look): the highlighted row's whole outcome with its target.
  const outcome = returnLook === "footer" ? rows[selected]?.choice.outcome : undefined;
  const outcomeId = `${menuId}-outcome`;
  const openMenu = useCallback(() => {
    dispatch.current += 1;
    setError(undefined);
    setQuery("");
    setSearchHeight(undefined);
    setActive(0);
    setOpen(true);
    onOpen?.();
    focusWithRing(trigger.current, { focusVisible: false });
  }, [onOpen]);
  const close = useCallback(() => {
    dispatch.current += 1;
    setOpen(false);
    setQuery("");
    if (returnFocus) trigger.current?.focus();
  }, [returnFocus]);
  const press = usePopoverTrigger(open, setOpen, openMenu, { popup: "listbox", popupId: menuId });
  useEffect(() => {
    if (!open) return;
    search.current?.focus({ preventScroll: true });
    const outside = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) close();
    };
    const blur = () => setOpen(false);
    document.addEventListener("pointerdown", outside, true);
    window.addEventListener("blur", blur);
    return () => {
      document.removeEventListener("pointerdown", outside, true);
      window.removeEventListener("blur", blur);
    };
  }, [open, close]);
  useEffect(() => {
    setActive((current) => Math.min(current, Math.max(rows.length - 1, 0)));
  }, [rows.length]);
  useEffect(() => {
    if (!open || !rows.length) return;
    scrollActiveMenuRow(menu.current, `${menuId}-${selected}`);
  }, [open, rows.length, menuId, selected]);
  useEffect(() => registerPicker(label, openMenu), [label, openMenu]);
  const pick = async (index: number) => {
    const row = rows[index];
    if (!row) return;
    const attempt = ++dispatch.current;
    setError(undefined);
    try {
      const result = await row.section.onPick?.(row.choice.id);
      if (dispatch.current === attempt && menu.current && result !== "keep") close();
    } catch (reason) {
      if (dispatch.current !== attempt || !menu.current) return;
      setError(
        reason instanceof Error
          ? t("harnesses.commandFailedBecause", { reason: reason.message })
          : t("harnesses.commandFailed"),
      );
    }
  };
  // `app.keyStyle`: in the list Vim's j/k, gg/G and l (pick), / (the search field); in the field
  // Vim's Esc (Emacs' Ctrl-G) gives the keyboard to the list, whose Esc closes as before; Emacs'
  // Ctrl-N/P move in both and Ctrl-A/E go to the ends in the list.
  const listKeys = useListKeys({
    onCommand: (command, event) => {
      const inField = event.target === search.current;
      if (command === "list.next" || command === "list.previous") {
        const step = command === "list.next" ? 1 : -1;
        if (rows.length) setActive((current) => (current + step + rows.length) % rows.length);
        return;
      }
      if (command === "list.leave") {
        const list = menu.current?.ownerDocument.getElementById(menuId);
        if (!inField || !list) return false;
        focusRoute(list, "person", "key style list key", { preventScroll: true });
        return;
      }
      if (inField) return false;
      if (command === "list.first" || command === "list.last") {
        if (rows.length) setActive(command === "list.first" ? 0 : rows.length - 1);
      } else if (command === "list.open") void pick(selected);
      else if (command === "list.search")
        focusRoute(search.current, "person", "key style list key", { preventScroll: true });
      else return false;
    },
  });
  const keyDown = (event: React.KeyboardEvent) => {
    // IME commit keys (including WebKit's keyCode 229 after compositionend) belong to the
    // editor. Never dispatch or close the palette for them; the following plain Enter may pick.
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
    listKeys(event);
    if (event.defaultPrevented) return;
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      setOpen(false);
      search.current?.blur();
      focusAfterEscape(trigger.current);
      return;
    }
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      if (rows.length) setActive((current) => (current + step + rows.length) % rows.length);
    } else if (
      (event.key === "Home" || event.key === "End") &&
      event.currentTarget.getAttribute("role") === "listbox"
    ) {
      event.preventDefault();
      if (rows.length) setActive(event.key === "Home" ? 0 : rows.length - 1);
    } else if (event.key === "Enter") {
      event.preventDefault();
      void pick(selected);
    } else if (event.key === "Tab") {
      setOpen(false);
      setQuery("");
    }
  };
  let index = -1;
  return (
    <span
      ref={root}
      className={`acpmux-picker ${className}`}
      style={{ position: "relative" }}
      onBlur={(event) => {
        if (open && !root.current?.contains(event.relatedTarget as Node | null)) {
          setOpen(false);
          setQuery("");
        }
      }}
    >
      <button
        ref={trigger}
        type="button"
        className="acpmux-picker-button"
        data-menu={label}
        aria-label={label}
        // tooltip-allow: the trigger is the caller's glyph (the composer's +), with no words of its own.
        title={tooltip}
        onKeyDown={(event) => {
          if (!open && (event.key === "ArrowDown" || event.key === "ArrowUp")) {
            event.preventDefault();
            openMenu();
          }
        }}
        {...press}
        onPointerDown={(event) => {
          if (event.button !== 0) return;
          const pointer = isMousePress(event);
          press.onPointerDown(event);
          if (!pointer) openMenu();
        }}
      >
        {button}
      </button>
      {open && (
        <div
          ref={attach}
          style={{ ...menuStyle, height: searchHeight }}
          className={`ui-popup ui-glass acpmux-menu acpmux-palette-menu acpmux-menu-${align}`}
        >
          <div className="acpmux-palette-search">
            <input
              ref={search}
              type="search"
              value={query}
              onChange={(event) => {
                // Preserve the opening surface while filtering an above-anchored menu, so
                // the search field stays under the pointer. The anchor's maxHeight still
                // constrains this height when the pane becomes smaller.
                if (searchHeight === undefined && menu.current)
                  setSearchHeight(Number.parseFloat(window.getComputedStyle(menu.current).height));
                setQuery(event.currentTarget.value);
              }}
              onKeyDown={keyDown}
              // oxlint-disable-next-line jsx-a11y/no-redundant-roles
              role="combobox"
              aria-haspopup="listbox"
              aria-expanded={open}
              aria-controls={menuId}
              aria-label={searchLabel}
              aria-describedby={outcome ? outcomeId : undefined}
              aria-activedescendant={rows.length ? `${menuId}-${selected}` : undefined}
              placeholder={searchLabel}
              autoComplete="off"
            />
          </div>
          {error && (
            <div className="acpmux-palette-empty" role="alert">
              {error}
            </div>
          )}
          {/* A native select cannot hold descriptions, sections or search. */}
          <div
            ref={edges}
            id={menuId}
            className="acpmux-palette-list"
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
            role="listbox"
            tabIndex={-1}
            aria-label={label}
            onKeyDown={keyDown}
          >
            {filtered.map((section, s) => (
              <React.Fragment key={section.title}>
                {/* The shared menu separator (ui/popupSurface.css) splits the groups; the groups name themselves. */}
                {s > 0 && <div className="ui-separator" aria-hidden="true" />}
                <div
                  className="acpmux-menu-section"
                  // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                  role="group"
                  aria-label={section.title}
                >
                  <div className="acpmux-menu-header">{section.title}</div>
                  {section.choices.map((choice) => {
                    index += 1;
                    const at = index;
                    const description =
                      quietDescriptions && descriptionRestatesName(choice.name, choice.description)
                        ? undefined
                        : choice.description;
                    // Return's row says so before Return: the keycap the slash menu, New Tab and the cards use,
                    // and under the `verb` and `footer` looks the verb Return carries out.
                    const verb =
                      returnLook === "verb" || returnLook === "footer" ? (choice.verb ?? section.verb) : undefined;
                    return (
                      <div
                        key={`${section.title}-${choice.id}`}
                        id={`${menuId}-${at}`}
                        data-value={choice.id}
                        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                        role="option"
                        tabIndex={-1}
                        aria-selected={at === selected}
                        className={`acpmux-menu-item${at === selected ? " acpmux-menu-active" : ""}`}
                        onMouseMove={() => at !== selected && setActive(at)}
                        onMouseDown={(event) => {
                          if (event.button !== 0) return;
                          event.preventDefault();
                          void pick(at);
                        }}
                      >
                        {choice.icon}
                        <span className="acpmux-menu-text">
                          <span className="acpmux-menu-label">{choice.name}</span>
                          {description && <span className="acpmux-menu-description">{description}</span>}
                        </span>
                        {choice.hint &&
                          (hintIsKey(choice.hint) ? (
                            <KeyHint keys={choice.hint} className="acpmux-menu-hint" />
                          ) : (
                            <span className="acpmux-menu-hint acpmux-menu-arg">{choice.hint}</span>
                          ))}
                        {returnLook !== "none" && at === selected && (
                          <span className="acpmux-palette-return" aria-hidden="true">
                            {verb && <span className="acpmux-palette-return-verb">{verb}</span>}
                            <KeyHint keys="↩" />
                          </span>
                        )}
                      </div>
                    );
                  })}
                </div>
              </React.Fragment>
            ))}
            {!rows.length && <div className="acpmux-palette-empty">{t("composer.noMatchingCommands")}</div>}
          </div>
          {outcome && (
            <div id={outcomeId} className="acpmux-palette-outcome">
              <KeyHint keys="↩" />
              <span className="acpmux-palette-outcome-text">{outcome}</span>
            </div>
          )}
        </div>
      )}
    </span>
  );
}
