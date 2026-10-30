import React, { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { focusAfterEscape } from "../../ui/escapeFocus";
import { focusWithRing } from "../../ui/focusWithRing";
import { UI_ANCHOR_GAP, useUiAnchor } from "../../ui/anchor";
import { useEscapingPopup } from "../../ui/popupHost";
import { usePopupHost } from "../../ui/UiProvider";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import { isMousePress } from "../../ui/pressRelease";
import { registerPicker } from "./pickerOpeners";
import { Icon as CmuxIcon } from "./icons/Icon";
import type { ComposerPlusExtension } from "./composerPlusRegistry";
import { useT, type Translate } from "./i18n";
import { scrollActiveMenuRow } from "./scrollActiveMenuRow";
import { useScrollEdges } from "./summary/scrollEdges";

export type PaletteChoice = {
  id: string;
  name: string;
  description?: string;
  icon?: React.ReactNode;
  hint?: string;
  keywords?: readonly string[];
};

export type PaletteSection = {
  title: string;
  choices: PaletteChoice[];
  onPick?: (id: string) => void | "keep" | Promise<void | "keep">;
};

type Props = {
  label: string;
  className?: string;
  button: React.ReactNode;
  sections: PaletteSection[];
  align?: "start" | "end";
  returnFocus?: boolean;
  tooltip?: string;
  onOpen?: () => void;
};

/** The tools and navigation exposed from the same native action catalog as Cmd-P. */
export function paletteSections(
  onAction: (id: string) => void | Promise<void>,
  t: Translate,
  extensions: readonly ComposerPlusExtension[] = [],
): PaletteSection[] {
  return (["tools", "apps", "sessions", "tabs"] as const).flatMap((section) => {
    const entries = extensions.filter((entry) => entry.section === section);
    return entries.length
      ? [
          {
            title: t(
              { tools: "plus.tools", apps: "plus.apps", sessions: "sidebar.sessions", tabs: "newTab.openTabs" }[
                section
              ] as Parameters<Translate>[0],
            ),
            choices: entries.map((entry) => ({
              id: entry.id,
              name: entry.name,
              description: entry.description,
              keywords: entry.keywords,
              icon: <CmuxIcon name={entry.icon} size={16} />,
            })),
            onPick: (id: string) => {
              const entry = entries.find((row) => row.id === id);
              if (entry?.action.kind !== "command") return "keep" as const;
              return onAction(entry.action.id);
            },
          },
        ]
      : [];
  });
}

export function filterPaletteSections(sections: readonly PaletteSection[], query: string): PaletteSection[] {
  const text = query.trim().toLocaleLowerCase();
  return sections
    .map((section) => ({
      ...section,
      choices: text
        ? section.choices.filter((choice) =>
            [choice.name, choice.description ?? "", ...(choice.keywords ?? [])]
              .join(" ")
              .toLocaleLowerCase()
              .includes(text),
          )
        : section.choices,
    }))
    .filter((section) => section.choices.length > 0);
}

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
  const attach = useCallback(
    (node: HTMLDivElement | null) => {
      menu.current = node;
      if (host) setShown(node);
    },
    [host],
  );
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
  const press = usePopoverTrigger(open, setOpen, openMenu);
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
  const keyDown = (event: React.KeyboardEvent) => {
    // IME commit keys (including WebKit's keyCode 229 after compositionend) belong to the
    // editor. Never dispatch or close the palette for them; the following plain Enter may pick.
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
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
        title={tooltip}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
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
              aria-label={t("sidebar.searchPlaceholder")}
              aria-activedescendant={rows.length ? `${menuId}-${selected}` : undefined}
              placeholder={t("sidebar.searchPlaceholder")}
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
                          {choice.description && <span className="acpmux-menu-description">{choice.description}</span>}
                        </span>
                        {choice.hint && <kbd className="acpmux-menu-hint">{choice.hint}</kbd>}
                      </div>
                    );
                  })}
                </div>
              </React.Fragment>
            ))}
            {!rows.length && <div className="acpmux-palette-empty">{t("composer.noMatchingCommands")}</div>}
          </div>
        </div>
      )}
    </span>
  );
}
