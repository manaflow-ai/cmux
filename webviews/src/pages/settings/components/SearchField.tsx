import { useId } from "react";
import { Input } from "../../../ui/Input";
import { focusRoute } from "../../../ui/focusRoute";
import { Icon } from "../icons";
import { t } from "../strings";
import { focusFirstRow } from "../keyboard";
import { useListKeys } from "../../../ui/useListKeys";

const focusOnMount = (element: HTMLInputElement | null) => element?.focus();

/**
 * The search field (P5), focused when the page opens, the sidebar's full width. Esc clears the
 * query; a second Esc moves focus to the category list. Return reveals the first result.
 */
export function SearchField({
  query,
  onQuery,
  onSubmit,
}: {
  query: string;
  onQuery: (query: string) => void;
  onSubmit: () => void;
}) {
  const searchId = useId();
  // `app.keyStyle` (the page's rows, SettingsApp): Vim's Esc and Emacs' Ctrl-G give the keyboard
  // to the rows, as Down does; Emacs' Ctrl-N is Down. Without a row Esc does what it did.
  const styleKeys = useListKeys({
    onCommand: (command, event) => {
      if (command !== "list.leave" && command !== "list.next") return false;
      return focusFirstRow((event.target as Element).ownerDocument);
    },
  });
  return (
    <div className="search-bar">
      <label className="search" htmlFor={searchId}>
        <Icon name="search" />
        <Input
          id={searchId}
          size="lg"
          ref={focusOnMount}
          className="field search-input"
          type="search"
          data-settings-search=""
          value={query}
          placeholder={t("settingsPage.search")}
          aria-label={t("settingsPage.search")}
          spellCheck={false}
          onChange={(event) => onQuery(event.currentTarget.value)}
          onKeyDown={(event) => {
            styleKeys(event);
            if (event.defaultPrevented) return;
            if (event.key === "Escape") {
              event.preventDefault();
              if (query) onQuery("");
              else {
                const current = event.currentTarget.ownerDocument.querySelector<HTMLElement>(
                  ".section-list .section-link[aria-current]",
                );
                focusRoute(current, "person", "Escape from Settings search to the current sidebar link");
              }
            } else if (event.key === "Enter") {
              event.preventDefault();
              onSubmit();
            }
          }}
        />
      </label>
    </div>
  );
}
