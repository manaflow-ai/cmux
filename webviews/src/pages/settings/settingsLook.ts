import { useLayoutEffect, useSyncExternalStore } from "react";

const attribute = "data-settings-look";
const isRefined = () => document.documentElement.getAttribute(attribute) === "refined";

function subscribe(onChange: () => void): () => void {
  const observer = new MutationObserver(onChange);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: [attribute] });
  return () => observer.disconnect();
}

/** The preview follows the same attribute as the stylesheet, including live host changes. */
export function useRefinedSettingsLook(): boolean {
  return useSyncExternalStore(subscribe, isRefined, () => false);
}

/** The look the page had before the refined one took over (mount.tsx SHIPPED_LOOK, or a gallery variant). */
let previous: string | null = null;

/** Host facts own the app variant; the browser preview also accepts ?look=refined. Turning it off
 * puts back the look the page had before. */
export function useSettingsLookAttribute(refined: boolean): void {
  const preview = new URLSearchParams(window.location.search).get("look") === "refined";
  useLayoutEffect(() => {
    const root = document.documentElement;
    if (refined || preview) {
      if (!isRefined()) previous = root.getAttribute(attribute);
      root.setAttribute(attribute, "refined");
    } else if (isRefined()) {
      if (previous === null) root.removeAttribute(attribute);
      else root.setAttribute(attribute, previous);
    }
  }, [refined, preview]);
}
