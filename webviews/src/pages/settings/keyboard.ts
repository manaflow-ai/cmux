// Plain keys only (react-pages.md 1.2, Q3): Up/Down between rows, Space toggles a row's
// switch, Return reveals a search result (or enters a row's control). The page never handles
// Cmd or Ctrl chords; the app's key dispatcher owns them and sends page commands
// (`cmux.page.command`: find, back, forward, reset), which `runPageCommand` performs.
export type KeyboardActions = {
  back(): void;
  forward(): void;
  reveal(key: string): void;
  reset(key: string): void;
};

/** Commands the app's key dispatcher sends to the focused page. */
export type PageCommand = "find" | "focusSearch" | "back" | "forward" | "reset";

const rowSelector = "[data-row-key], [data-action-row]";
const controlSelector = "button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled)";

export function focusSearch(doc: Document): void {
  const input = doc.querySelector<HTMLInputElement>("[data-settings-search]");
  input?.focus();
  input?.select();
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

export function installKeyboard(root: HTMLElement, actions: KeyboardActions): () => void {
  const doc = root.ownerDocument;
  const onKeyDown = (event: KeyboardEvent) => {
    const target = event.target instanceof doc.defaultView!.Element ? event.target : doc.body;
    if (event.metaKey || event.altKey || event.ctrlKey) return;
    const rows = [...root.querySelectorAll<HTMLElement>(".content [data-row-key], .content [data-action-row]")];
    const onSearch = target.matches("[data-settings-search]");
    const onRow = target.matches(rowSelector);
    if (event.key === "ArrowDown" && onSearch) rows[0]?.focus();
    else if ((event.key === "ArrowDown" || event.key === "ArrowUp") && onRow) {
      const index = rows.indexOf(target as HTMLElement) + (event.key === "ArrowDown" ? 1 : -1);
      if (index < 0) focusSearch(doc);
      else rows[Math.min(index, rows.length - 1)]?.focus();
    } else if (event.key === " " && onRow) {
      target.querySelector<HTMLElement>("[role=switch]:not(:disabled)")?.click();
    } else if (event.key === "Enter" && onRow) {
      if (target.closest("[data-search-results]")) actions.reveal(target.getAttribute("data-row-key")!);
      else focusControl(target);
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
    const key = active.closest(rowSelector)?.getAttribute("data-row-key");
    if (key) actions.reset(key);
  }
}
