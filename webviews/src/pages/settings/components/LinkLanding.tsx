// Where a settings deep link lands (settingsLinks.ts): the page scrolls its target (a row, a card, a
// connection) into view and highlights it for a moment; a link that named nothing, or a connection the
// host does not draw, gets a named line at the top of the page instead of a silent guess.
import { useEffect, useState } from "react";
import { t } from "../strings";

/** How long the page waits for a target that draws after its reads arrive. */
export const LINK_TARGET_WAIT_MS = 4_000;
/** How long the highlight stays. */
export const LINK_HIGHLIGHT_MS = 2_400;

/** The element a target selector names: a card slot is `display: contents`, so its first child. */
export function linkTargetElement(root: ParentNode, selector: string): HTMLElement | null {
  const found = root.querySelector<HTMLElement>(selector);
  if (!found) return null;
  if (found.hasAttribute("data-card-slot")) return (found.firstElementChild as HTMLElement | null) ?? null;
  return found;
}

/** Highlights `target` once it draws (and scrolls to it when `scroll`); true when a required one never draws. */
export function useLinkLanding(target: string | null, required: boolean, scroll = required): boolean {
  const [absent, setAbsent] = useState(false);
  useEffect(() => {
    setAbsent(false);
    if (!target || typeof document === "undefined") return;
    const root = document.querySelector(".content") ?? document;
    let cleared: ReturnType<typeof setTimeout> | undefined;
    let landed: HTMLElement | null = null;
    const land = (): boolean => {
      const element = linkTargetElement(root, target);
      if (!element) return false;
      landed = element;
      // A card scrolls itself to the top once its rows draw (its `reveal` prop) and a focused row
      // centers itself (revealRow): both own their timing, so here only a connection's row, which
      // nothing else reveals, scrolls; every target is highlighted.
      if (scroll) element.scrollIntoView?.({ block: "start" });
      element.setAttribute("data-link-target", "");
      cleared = setTimeout(() => element.removeAttribute("data-link-target"), LINK_HIGHLIGHT_MS);
      return true;
    };
    if (land()) return () => clearTimeout(cleared);
    const observer = new MutationObserver(() => {
      if (land()) {
        observer.disconnect();
        clearTimeout(giveUp);
      }
    });
    observer.observe(root, { childList: true, subtree: true });
    const giveUp = setTimeout(() => {
      observer.disconnect();
      if (required) setAbsent(true);
    }, LINK_TARGET_WAIT_MS);
    return () => {
      observer.disconnect();
      clearTimeout(giveUp);
      clearTimeout(cleared);
      (landed as HTMLElement | null)?.removeAttribute("data-link-target");
    };
  }, [target, required, scroll]);
  return absent;
}

/** The line a link that landed on nothing shows, naming what it asked for. */
export function LinkMissing({ name }: { name: string }) {
  return (
    <output className="link-missing row-help" data-link-missing={name}>
      {t("settingsPage.link.missing", name)}
    </output>
  );
}
