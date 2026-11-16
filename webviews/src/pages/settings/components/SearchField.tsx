import { useId } from "react";
import { Input } from "../../../ui/Input";
import { Icon } from "../icons";
import { t } from "../strings";

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
    </div>
  );
}
