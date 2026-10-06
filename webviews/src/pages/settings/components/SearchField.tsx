import { Icon } from "../icons";
import { t } from "../strings";

const focusOnMount = (element: HTMLInputElement | null) => element?.focus();

/**
 * The search field, focused when the page opens. Esc clears the query; a second Esc moves
 * focus to the section list. Return reveals the first result.
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
  return (
    <label className="search">
      <Icon name="search" />
      <input
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
          if (event.key === "Escape") {
            event.preventDefault();
            if (query) onQuery("");
            else
              event.currentTarget.ownerDocument
                .querySelector<HTMLElement>("[data-section-link][aria-current]")
                ?.focus();
          } else if (event.key === "Enter") {
            event.preventDefault();
            onSubmit();
          }
        }}
      />
    </label>
  );
}
