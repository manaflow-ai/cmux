// Diff toolbar controls: the source menu pill, the jump-to-file palette, the
// floating toolbar pill and its "..." options menu. State lives in App; the
// models (what each control shows and does) are in toolbar-model.ts.
import { useEffect, useId, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { DiffItem } from "./diff-stream";
import { Icon, type IconName } from "./icons";
import type { DiffViewerLabelResolver } from "./labels";
import {
  jumpToFileRows,
  rovingIndex,
  type OverflowMenuItem,
  type OverflowMenuItemId,
  type PillButton,
  type PillButtonId,
  type SourceMenuEntry,
  type SourceMenuModel,
  type SourceTarget,
} from "./toolbar-model";

// ---------------------------------------------------------------------------
// Anchored popovers
// ---------------------------------------------------------------------------

type AnchorStyle = Pick<React.CSSProperties, "top" | "left" | "maxHeight" | "width">;
const POPOVER_GAP = 6;
const VIEWPORT_MARGIN = 8;

/**
 * Viewport position for a popover portaled to `document.body`, under its anchor
 * and clamped to the viewport. The toolbar cells clip horizontally and are
 * container-query containers (a containing block for fixed descendants), so a
 * popover left inside them would be clipped. Recomputed on resize and scroll.
 */
function useAnchoredPopover(open: boolean, anchorRef: React.RefObject<HTMLElement | null>, width: number) {
  const [style, setStyle] = useState<AnchorStyle | null>(null);
  useEffect(() => {
    if (!open) {
      setStyle(null);
      return;
    }
    const reposition = () => {
      const anchor = anchorRef.current;
      if (!anchor) return;
      const rect = anchor.getBoundingClientRect();
      const fitted = Math.min(width, window.innerWidth - VIEWPORT_MARGIN * 2);
      const left = Math.max(VIEWPORT_MARGIN, Math.min(rect.left, window.innerWidth - fitted - VIEWPORT_MARGIN));
      const top = rect.bottom + POPOVER_GAP;
      setStyle({ top, left, width: fitted, maxHeight: Math.max(120, window.innerHeight - top - VIEWPORT_MARGIN) });
    };
    reposition();
    window.addEventListener("resize", reposition);
    window.addEventListener("scroll", reposition, true);
    return () => {
      window.removeEventListener("resize", reposition);
      window.removeEventListener("scroll", reposition, true);
    };
  }, [anchorRef, open, width]);
  return style;
}

/** Closes an open popover on a press outside `refs`. One listener per open popover. */
function useDismissOnOutsidePress(open: boolean, refs: React.RefObject<HTMLElement | null>[], onDismiss: () => void) {
  const latest = useRef({ refs, onDismiss });
  latest.current = { refs, onDismiss };
  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: MouseEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (latest.current.refs.some((ref) => ref.current?.contains(target))) return;
      latest.current.onDismiss();
    };
    document.addEventListener("mousedown", onPointerDown);
    return () => document.removeEventListener("mousedown", onPointerDown);
  }, [open]);
}

/** Arrow, Home and End move focus between a menu's enabled items. */
function onMenuKeyDown(event: React.KeyboardEvent<HTMLElement>, onEscape: () => void) {
  if (event.key === "Escape") {
    event.preventDefault();
    event.stopPropagation();
    onEscape();
    return;
  }
  const menu = event.currentTarget;
  const items = Array.from(menu.querySelectorAll<HTMLElement>("[role^='menuitem']")).filter(
    (item) => item.closest("[role='menu']") === menu,
  );
  const current = items.indexOf(document.activeElement as HTMLElement);
  const next = rovingIndex(event.key, current < 0 ? -1 : current, items.length, "vertical");
  if (next != null) {
    event.preventDefault();
    items[next]?.focus();
  }
}

function focusFirstMenuItem(node: HTMLElement | null) {
  const target =
    node?.querySelector<HTMLElement>("[role^='menuitem']:not([aria-disabled='true'])") ??
    node?.querySelector<HTMLElement>("[role^='menuitem']");
  target?.focus();
}

// ---------------------------------------------------------------------------
// Source menu
// ---------------------------------------------------------------------------

export function SourceMenu({
  additions,
  deletions,
  label,
  model,
  onSelect,
}: {
  additions: number;
  deletions: number;
  label: DiffViewerLabelResolver;
  model: SourceMenuModel;
  onSelect: (target: SourceTarget) => void;
}) {
  const [open, setOpen] = useState(false);
  const [committedOpen, setCommittedOpen] = useState(false);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);
  const menuId = useId();
  const style = useAnchoredPopover(open, buttonRef, 230);
  const close = (refocus = true) => {
    setOpen(false);
    setCommittedOpen(false);
    if (refocus) buttonRef.current?.focus();
  };
  useDismissOnOutsidePress(open, [buttonRef, menuRef], () => close(false));
  const entryText = (entry: SourceMenuEntry) => entry.text ?? (entry.labelKey ? label(entry.labelKey) : entry.id);
  const choose = (entry: SourceMenuEntry) => {
    if (!entry.target) return;
    close();
    if (!entry.checked) onSelect(entry.target);
  };
  const selectedText = model.selected ? entryText(model.selected) : label("diffTarget");
  return (
    <div id="source-menu" className="source-pill">
      <button
        ref={buttonRef}
        id="source-menu-button"
        type="button"
        className="source-pill-button"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        aria-label={`${label("diffTarget")}: ${selectedText}`}
        onClick={() => (open ? close(false) : setOpen(true))}
        onKeyDown={(event) => {
          if (event.key === "ArrowDown" && !open) {
            event.preventDefault();
            setOpen(true);
          }
        }}
      >
        <span className="source-pill-label">{selectedText}</span>
        <Icon name="chevronDown" />
      </button>
      <span className="source-pill-stats" aria-label={label("diffStats")}>
        <span className="source-pill-additions" title={label("additions")}>
          +{additions}
        </span>
        <span className="source-pill-deletions" title={label("deletions")}>
          -{deletions}
        </span>
      </span>
      {open && style
        ? createPortal(
            <div
              ref={(node) => {
                menuRef.current = node;
                if (node && !node.contains(document.activeElement)) focusFirstMenuItem(node);
              }}
              id={menuId}
              className="toolbar-menu source-menu"
              role="menu"
              tabIndex={-1}
              aria-label={label("diffTarget")}
              style={style}
              onKeyDown={(event) => onMenuKeyDown(event, () => close())}
            >
              {model.sections.map((section, index) => (
                <div key={section[0]?.id ?? index} className="toolbar-menu-section">
                  {index > 0 ? <hr className="menu-separator" /> : null}
                  {section.map((entry) =>
                    entry.children ? (
                      <div
                        key={entry.id}
                        className="toolbar-submenu-anchor"
                        onMouseEnter={() => setCommittedOpen(true)}
                        onMouseLeave={() => setCommittedOpen(false)}
                      >
                        <button
                          type="button"
                          role="menuitem"
                          className="menu-item toolbar-menu-item"
                          aria-haspopup="menu"
                          aria-expanded={committedOpen}
                          data-checked={entry.checked}
                          onClick={() => setCommittedOpen((value) => !value)}
                          onKeyDown={(event) => {
                            if (event.key === "ArrowRight" || event.key === "Enter" || event.key === " ") {
                              event.preventDefault();
                              event.stopPropagation();
                              setCommittedOpen(true);
                            }
                          }}
                        >
                          <span className="menu-label">{entryText(entry)}</span>
                          <span className="menu-check">
                            <Icon name="chevronRight" />
                          </span>
                        </button>
                        {committedOpen ? (
                          <div
                            ref={focusFirstMenuItem}
                            className="toolbar-menu toolbar-submenu"
                            role="menu"
                            tabIndex={-1}
                            aria-label={entryText(entry)}
                            onKeyDown={(event) => {
                              if (event.key === "ArrowLeft") {
                                event.preventDefault();
                                event.stopPropagation();
                                setCommittedOpen(false);
                                (event.currentTarget.previousElementSibling as HTMLElement | null)?.focus();
                                return;
                              }
                              onMenuKeyDown(event, () => close());
                              event.stopPropagation();
                            }}
                          >
                            {entry.children.length === 0 ? (
                              <div
                                className="menu-item toolbar-menu-item"
                                role="menuitem"
                                aria-disabled="true"
                                tabIndex={-1}
                              >
                                <span className="menu-label">{label("sourceNoCommits")}</span>
                              </div>
                            ) : (
                              entry.children.map((child) => (
                                <SourceMenuRow
                                  key={child.id}
                                  entry={child}
                                  label={label}
                                  text={entryText(child)}
                                  onChoose={() => choose(child)}
                                />
                              ))
                            )}
                          </div>
                        ) : null}
                      </div>
                    ) : (
                      <SourceMenuRow
                        key={entry.id}
                        entry={entry}
                        label={label}
                        text={entryText(entry)}
                        onChoose={() => choose(entry)}
                      />
                    ),
                  )}
                </div>
              ))}
            </div>,
            document.body,
          )
        : null}
    </div>
  );
}

function SourceMenuRow({
  entry,
  label,
  onChoose,
  text,
}: {
  entry: SourceMenuEntry;
  label: DiffViewerLabelResolver;
  onChoose: () => void;
  text: string;
}) {
  const unavailable = entry.target == null;
  return (
    <button
      type="button"
      role="menuitemradio"
      className="menu-item toolbar-menu-item"
      data-source-id={entry.id}
      aria-checked={entry.checked}
      aria-disabled={unavailable || undefined}
      title={unavailable ? label("optionNeedsHostSupport") : undefined}
      onClick={() => {
        if (!unavailable) onChoose();
      }}
    >
      <span className="menu-label">{text}</span>
      <span className="menu-check">{entry.checked ? <Icon name="check" /> : null}</span>
    </button>
  );
}

// ---------------------------------------------------------------------------
// Jump to file palette
// ---------------------------------------------------------------------------

export function JumpToFilePalette({
  items,
  label,
  onJump,
}: {
  items: DiffItem[];
  label: DiffViewerLabelResolver;
  onJump: (itemId: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [highlight, setHighlight] = useState(0);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const paletteRef = useRef<HTMLDivElement | null>(null);
  const listboxId = useId();
  const style = useAnchoredPopover(open, buttonRef, 440);
  useDismissOnOutsidePress(open, [buttonRef, paletteRef], () => setOpen(false));
  if (items.length === 0) {
    return null;
  }
  const { rows, hidden } = open ? jumpToFileRows(items, query, label("untitled")) : { rows: [], hidden: 0 };
  const active = rows.length === 0 ? 0 : Math.min(highlight, rows.length - 1);
  const close = () => {
    setOpen(false);
    buttonRef.current?.focus();
  };
  const jump = (id: string) => {
    setOpen(false);
    onJump(id);
  };
  return (
    <div id="jump-to-file">
      <button
        ref={buttonRef}
        id="jump-to-file-button"
        type="button"
        className="toolbar-round-button"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={label("jumpToFile")}
        title={label("jumpToFile")}
        onClick={() => {
          if (open) {
            setOpen(false);
            return;
          }
          setQuery("");
          setHighlight(0);
          setOpen(true);
        }}
      >
        <Icon name="chevronDown" />
      </button>
      {open && style
        ? createPortal(
            <div
              ref={paletteRef}
              className="toolbar-menu jump-palette"
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
              role="dialog"
              aria-label={label("jumpToFile")}
              style={style}
            >
              <div className="jump-palette-search">
                <Icon name="search" />
                <input
                  ref={(node) => node?.focus()}
                  type="text"
                  className="jump-palette-input"
                  placeholder={label("jumpToFile")}
                  aria-label={label("jumpToFile")}
                  aria-controls={listboxId}
                  aria-activedescendant={rows[active] ? `${listboxId}-${active}` : undefined}
                  value={query}
                  onChange={(event) => {
                    setQuery(event.currentTarget.value);
                    setHighlight(0);
                  }}
                  onKeyDown={(event) => {
                    if (event.key === "Escape") {
                      event.preventDefault();
                      event.stopPropagation();
                      close();
                      return;
                    }
                    if (event.key === "Enter") {
                      event.preventDefault();
                      if (rows[active]) jump(rows[active].id);
                      return;
                    }
                    const next = rovingIndex(
                      event.key === "Home" || event.key === "End" ? "" : event.key,
                      active,
                      rows.length,
                      "vertical",
                    );
                    if (next != null) {
                      event.preventDefault();
                      setHighlight(next);
                      document.getElementById(`${listboxId}-${next}`)?.scrollIntoView({ block: "nearest" });
                    }
                  }}
                />
              </div>
              {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
              <div id={listboxId} className="jump-palette-list" role="listbox" aria-label={label("jumpToFile")}>
                {rows.length === 0 ? (
                  <div className="jump-palette-status">{label("jumpToFileNoMatches")}</div>
                ) : (
                  rows.map((row, index) => (
                    <div
                      key={row.id}
                      id={`${listboxId}-${index}`}
                      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                      role="option"
                      tabIndex={-1}
                      aria-selected={index === active}
                      className={index === active ? "jump-palette-row jump-palette-row-active" : "jump-palette-row"}
                      onMouseMove={() => setHighlight(index)}
                      onMouseDown={(event) => {
                        event.preventDefault();
                        jump(row.id);
                      }}
                    >
                      <span className="jump-palette-name">{row.name}</span>
                      {row.directory ? <span className="jump-palette-dir">{row.directory}</span> : null}
                    </div>
                  ))
                )}
                {hidden > 0 ? (
                  <div className="jump-palette-status">
                    {label("jumpToFileMore").replace("{count}", String(hidden))}
                  </div>
                ) : null}
              </div>
            </div>,
            document.body,
          )
        : null}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Floating toolbar pill and its "..." menu
// ---------------------------------------------------------------------------

export function FloatingToolbar({
  buttons,
  label,
  menuItems,
  menuOpen,
  onButton,
  onCloseMenu,
  onMenuItem,
  viewMenu,
}: {
  buttons: PillButton[];
  label: DiffViewerLabelResolver;
  menuItems: OverflowMenuItem[];
  menuOpen: boolean;
  onButton: (id: PillButtonId) => void;
  onCloseMenu: () => void;
  onMenuItem: (id: OverflowMenuItemId) => void;
  /** Further view options rendered under the main menu rows. */
  viewMenu?: React.ReactNode;
}) {
  const [focusIndex, setFocusIndex] = useState(0);
  const toolbarRef = useRef<HTMLDivElement | null>(null);
  const closeMenu = () => {
    onCloseMenu();
    document.getElementById("options-button")?.focus();
  };
  return (
    <div id="diff-pill" className="diff-pill-anchor">
      {menuOpen ? (
        <div
          ref={focusFirstMenuItem}
          id="options-menu"
          className="toolbar-menu options-menu"
          role="menu"
          tabIndex={-1}
          aria-label={label("options")}
          onKeyDown={(event) => onMenuKeyDown(event, closeMenu)}
        >
          {menuItems.map((item) => (
            <OverflowMenuRow key={item.id} item={item} label={label} onChoose={() => onMenuItem(item.id)} />
          ))}
          {viewMenu}
        </div>
      ) : null}
      <div
        ref={toolbarRef}
        className="diff-pill"
        role="toolbar"
        tabIndex={-1}
        aria-label={label("diffToolbar")}
        aria-orientation="horizontal"
        onKeyDown={(event) => {
          const next = rovingIndex(event.key, focusIndex, buttons.length, "horizontal");
          if (next == null || !(event.target instanceof HTMLButtonElement)) return;
          event.preventDefault();
          setFocusIndex(next);
          toolbarRef.current?.querySelectorAll<HTMLButtonElement>(".diff-pill-button")[next]?.focus();
        }}
      >
        {buttons.map((button, index) => (
          <button
            key={button.id}
            id={button.domId}
            type="button"
            className="diff-pill-button"
            data-pill={button.id}
            data-tooltip={label(button.labelKey)}
            aria-label={label(button.labelKey)}
            aria-pressed={button.pressed}
            aria-expanded={button.expanded}
            aria-haspopup={button.id === "options" ? "menu" : undefined}
            aria-controls={button.id === "options" && button.expanded ? "options-menu" : undefined}
            tabIndex={index === focusIndex ? 0 : -1}
            onFocus={() => setFocusIndex(index)}
            onClick={() => onButton(button.id)}
          >
            <Icon name={button.icon} />
          </button>
        ))}
      </div>
    </div>
  );
}

function OverflowMenuRow({
  item,
  label,
  onChoose,
}: {
  item: OverflowMenuItem;
  label: DiffViewerLabelResolver;
  onChoose: () => void;
}) {
  const toggle = item.checked !== undefined;
  return (
    <button
      type="button"
      role={toggle ? "menuitemcheckbox" : "menuitem"}
      className="menu-item toolbar-menu-item"
      data-option={item.id}
      aria-checked={toggle ? item.checked : undefined}
      aria-disabled={item.available ? undefined : true}
      title={item.available ? undefined : label("optionNeedsHostSupport")}
      onClick={() => {
        if (item.available) onChoose();
      }}
    >
      <Icon name={item.icon} />
      <span className="menu-label">{label(item.labelKey)}</span>
      <span className="menu-check">{item.checked ? <Icon name="check" /> : null}</span>
    </button>
  );
}

/** A plain options-menu row (for the view options under the main rows). */
export function ViewMenuButton({
  checked,
  icon,
  label,
  onClick,
}: {
  checked?: boolean;
  icon: IconName;
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      role={checked === undefined ? "menuitem" : "menuitemcheckbox"}
      className="menu-item toolbar-menu-item"
      aria-checked={checked}
      onClick={onClick}
    >
      <Icon name={icon} />
      <span className="menu-label">{label}</span>
      <span className="menu-check">{checked ? <Icon name="check" /> : null}</span>
    </button>
  );
}
