// Plain keys (react-pages.md 1.2, Q3): Up/Down between rows, Space toggles a row's switch,
// Return reveals a search result (or enters a row's control). The page handles no other Cmd or Ctrl
// chord than its `app.keyStyle` keys on a row (Emacs' Ctrl-N/P...) and, on the appearance pages, Cmd-Z and
// Shift-Cmd-Z outside a text field (the appearance Undo and Redo, AppearanceBar); the app's key dispatcher owns
// the rest and sends page commands (`cmux.page.command`: find, back, forward, reset), which
// `runPageCommand` performs.
import { focusSearchField } from "../shared/searchField";
import {
  createListKeys,
  keyEventFromDom,
  keyStyleSnapshot,
  type KeyStyleSettings,
  type ListCommand,
  type ListKeys,
  type ListOutcome,
} from "../../ui/keyStyle";
import { LIST_KEYS_PENDING_MS, MODIFIER_KEYS } from "../../ui/useListKeys";
import { focusRoute } from "../../ui/focusRoute";
export type KeyboardActions = {
  back(): void;
  forward(): void;
  reveal(key: string): void;
  reset(key: string): void;
};

/** Commands the app's key dispatcher sends to the focused page. */
export type PageCommand = "find" | "focusSearch" | "back" | "forward" | "reset";

// Rows outside the search filter stay mounted (collapsed) and are skipped.
const rowSelector = "[data-row-key]:not([data-filtered]), [data-action-row]";
// A hidden form mirror (aria-hidden) or an inert Reset is never a focus target.
const controlSelector =
  ":is(button, input, select, textarea):not(:disabled):not([aria-hidden='true']):not([inert]):not([inert] *)";

export function focusSearch(doc: Document): void {
  focusSearchField(doc, "[data-settings-search]");
}

export function focusControl(row: Element): boolean {
  const control = row.querySelector<HTMLElement>(`.row-control :is(${controlSelector})`);
  control?.focus();
  return control !== null;
}

/** Callback-ref target for the row named by `?focus=`: scroll to it and focus its control. */
export function revealRow(row: HTMLElement | null): void {
  if (!row) return;
  row.scrollIntoView?.({ block: "center" });
  if (!focusControl(row)) row.focus();
}

function isTextField(element: Element): boolean {
  if (element instanceof element.ownerDocument.defaultView!.HTMLTextAreaElement) return true;
  if (!(element instanceof element.ownerDocument.defaultView!.HTMLInputElement)) return false;
  return !["checkbox", "radio", "range", "color", "button"].includes(element.type);
}

/// The rows Up and Down step through, in order. Rows a narrower query filtered out, and rows of a
/// closed More Options, stay mounted but inert: they are not stops.
function stopRows(root: ParentNode): HTMLElement[] {
  return [...root.querySelectorAll<HTMLElement>(".content [data-row-key], .content [data-action-row]")].filter(
    (row) => !row.matches("[data-filtered]") && !row.closest("[data-filtered], [inert]"),
  );
}

/** The first row takes the keyboard (Down in the search field); false when there is none. */
export function focusFirstRow(doc: Document): boolean {
  const row = stopRows(doc)[0];
  focusRoute(row, "person", "Down from the search field");
  return row !== undefined;
}

/// The rows' `app.keyStyle` keys (the page's rows, through configureKeyStyle in SettingsApp):
/// Vim's j/k, gg/G and l and Emacs' alike step, reach the ends and open a row as Up, Down and
/// Return do; / and Ctrl-S go to the search field. The search field's own keys are SearchField's.
function rowStyleKeys(): (event: KeyboardEvent) => ListOutcome {
  let settings: KeyStyleSettings | undefined;
  let keys: ListKeys | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  return (event) => {
    const current = keyStyleSnapshot();
    if (current !== settings || !keys) {
      settings = current;
      keys = createListKeys(current.keyStyle, current.shortcutLayout);
    }
    if (event.defaultPrevented || event.isComposing || MODIFIER_KEYS.has(event.key)) return "pass";
    clearTimeout(timer);
    const outcome = keys.feed(keyEventFromDom(event), false);
    if (outcome === "pending") timer = setTimeout(() => keys?.reset(), LIST_KEYS_PENDING_MS);
    return outcome;
  };
}

export function installKeyboard(root: HTMLElement, actions: KeyboardActions): () => void {
  const doc = root.ownerDocument;
  const styleKeys = rowStyleKeys();
  const onKeyDown = (event: KeyboardEvent) => {
    const target = event.target instanceof doc.defaultView!.Element ? event.target : doc.body;
    const rows = () => stopRows(root);
    const onSearch = target.matches("[data-settings-search]");
    const onRow = target.matches(rowSelector);
    if (onRow) {
      const outcome = styleKeys(event);
      if (outcome === "pending") return event.preventDefault();
      if (outcome !== "pass" && runRowCommand(outcome, target as HTMLElement, rows(), actions)) {
        event.preventDefault();
        return;
      }
    }
    if (event.metaKey || event.altKey || event.ctrlKey) return;
    const list = rows();
    if (event.key === "ArrowDown" && onSearch) list[0]?.focus();
    else if ((event.key === "ArrowDown" || event.key === "ArrowUp") && onRow) {
      const index = list.indexOf(target as HTMLElement) + (event.key === "ArrowDown" ? 1 : -1);
      if (index < 0) focusSearch(doc);
      else list[Math.min(index, list.length - 1)]?.focus();
    } else if (event.key === " " && onRow) {
      target.querySelector<HTMLElement>("[role=switch]:not(:disabled)")?.click();
    } else if (event.key === "Enter" && onRow) {
      openRow(target, actions);
    } else return;
    event.preventDefault();
  };
  doc.addEventListener("keydown", onKeyDown);
  return () => doc.removeEventListener("keydown", onKeyDown);
}

/** Performs a dispatcher command; `reset` applies to the row that holds focus. */
export function runPageCommand(doc: Document, command: PageCommand, actions: KeyboardActions): void {
  if (command === "find" || command === "focusSearch") focusSearch(doc);
  else if (command === "back") actions.back();
  else if (command === "forward") actions.forward();
  else if (command === "reset") {
    const active = doc.activeElement;
    if (!active || isTextField(active)) return;
    // An editor that holds several keys (the Row Layout tabs) names the one its focus edits.
    const key =
      active.closest("[data-reset-key]")?.getAttribute("data-reset-key") ??
      active.closest(rowSelector)?.getAttribute("data-row-key");
    if (key) actions.reset(key);
  }
}

/** Return on a row: a search result is revealed, another row's control takes the keyboard. */
function openRow(row: Element, actions: KeyboardActions): void {
  if (row.closest("[data-search-results]")) actions.reveal(row.getAttribute("data-row-key")!);
  else focusControl(row);
}

/** A key style's command on a focused row, as Down, Up and Return do; false: not the rows'. */
function runRowCommand(command: ListCommand, row: HTMLElement, rows: HTMLElement[], actions: KeyboardActions): boolean {
  const doc = row.ownerDocument;
  const at = rows.indexOf(row);
  if (command === "list.next") focusRoute(rows[Math.min(at + 1, rows.length - 1)], "person", "key style list key");
  else if (command === "list.previous") {
    if (at - 1 < 0) focusSearch(doc);
    else focusRoute(rows[at - 1], "person", "key style list key");
  } else if (command === "list.first") focusRoute(rows[0], "person", "key style list key");
  else if (command === "list.last") focusRoute(rows.at(-1), "person", "key style list key");
  else if (command === "list.open") openRow(row, actions);
  else if (command === "list.search") focusSearch(doc);
  else return false;
  return true;
}
