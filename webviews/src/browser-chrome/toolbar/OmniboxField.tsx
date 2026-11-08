// The browser toolbar page's live omnibar field (pages/browser-toolbar): the real input, and the
// styled address or placeholder drawn over it at rest.
import { AddressText } from "../ui/BrowserToolbar";
import type { OmnibarPresentation } from "../omnibox/presentation";
import { emphasisFor } from "./view";

/** The real input, always mounted; at rest the styled address is drawn over its invisible text. */
export function OmniboxField({
  inputRef,
  presentation,
  placeholder,
}: {
  inputRef: (input: HTMLInputElement | null) => void;
  presentation: OmnibarPresentation;
  placeholder: string;
}) {
  const resting = !presentation.hasFocus;
  const host = emphasisFor(presentation);
  return (
    <div className="bc-omnibox-field" data-resting={resting || undefined}>
      <input
        ref={inputRef}
        id="browser.toolbar.omnibar"
        className="bc-omnibox-input"
        type="text"
        tabIndex={-1}
        spellCheck={false}
        autoComplete="off"
        autoCorrect="off"
        autoCapitalize="off"
        aria-label={placeholder}
        placeholder={placeholder}
      />
      <span className="bc-omnibox-overlay" aria-hidden="true">
        {resting &&
          (presentation.text ? (
            <AddressText text={presentation.text} host={host ?? undefined} editing={host === null} />
          ) : (
            <span className="bc-address-text bc-placeholder">{placeholder}</span>
          ))}
      </span>
    </div>
  );
}
