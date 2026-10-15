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

/** Host facts own the app variant; the browser preview also accepts ?look=refined. */
export function useSettingsLookAttribute(refined: boolean): void {
  const preview = new URLSearchParams(window.location.search).get("look") === "refined";
  useLayoutEffect(() => {
    if (refined || preview) document.documentElement.setAttribute(attribute, "refined");
    else if (isRefined()) document.documentElement.removeAttribute(attribute);
  }, [refined, preview]);
}
