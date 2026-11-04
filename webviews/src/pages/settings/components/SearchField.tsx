import { useId } from "react";
import { Input } from "../../../ui/Input";
import { Button } from "../../../ui/Button";
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
  const searchId = useId();
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
      <Tooltip /* tooltip-allow: an icon and a count; the tooltip names the filter */ label={filterLabel}>
        <Button
          type="button"
          variant="ghost"
          size="lg"
          className="icon-button filter-button"
          data-changed-only=""
          aria-label={filterLabel}
          aria-pressed={changedOnly}
          onClick={() => onChangedOnly(!changedOnly)}
        >
          <Icon name="filter" />
          {changedCount > 0 && <span className="filter-count">{changedCount}</span>}
        </Button>
      </Tooltip>
    </div>
  );
}
