// Page keys, installed on the document by a callback ref on the page root:
// Cmd-F search, Cmd-[ / Cmd-] history, Up/Down between rows, Space toggles a row's switch,
// Return reveals a search result (or enters a row's control), Cmd-Backspace resets the row.
export type KeyboardActions = {
  back(): void;
  forward(): void;
  reveal(key: string): void;
  reset(key: string): void;
};

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
    if (event.metaKey && !event.altKey && !event.ctrlKey) {
      if (event.key === "f") focusSearch(doc);
      else if (event.key === "[") actions.back();
      else if (event.key === "]") actions.forward();
      else if (event.key === "Backspace" && !isTextField(target)) {
        const key = target.closest(rowSelector)?.getAttribute("data-row-key");
        if (!key) return;
        actions.reset(key);
      } else return;
      event.preventDefault();
      return;
    }
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
