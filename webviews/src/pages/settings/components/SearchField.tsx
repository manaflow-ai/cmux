import { Tooltip } from "../../../ui/Tooltip";
import { Icon } from "../icons";
import { t } from "../strings";

const focusOnMount = (element: HTMLInputElement | null) => element?.focus();

/**
 * The search field (P5), focused when the page opens, with the Show Only Changed filter (P4) at
 * its end. Esc clears the query; a second Esc moves focus to the category list. Return reveals
 * the first result.
 */
export function SearchField({
  query,
  onQuery,
  onSubmit,
  changedOnly,
  changedCount,
  onChangedOnly,
}: {
  query: string;
  onQuery: (query: string) => void;
  onSubmit: () => void;
  changedOnly: boolean;
  changedCount: number;
  onChangedOnly: (on: boolean) => void;
}) {
  const filterLabel = t("settingsPage.changedOnly");
  return (
    <div className="search-bar">
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
      <Tooltip label={filterLabel}>
        <button
          type="button"
          className="icon-button filter-button"
          data-changed-only=""
          aria-label={filterLabel}
          aria-pressed={changedOnly}
          onClick={() => onChangedOnly(!changedOnly)}
        >
          <Icon name="filter" />
          {changedCount > 0 && <span className="filter-count">{changedCount}</span>}
        </button>
      </Tooltip>
    </div>
  );
}
