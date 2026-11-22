// SOLID POPUPS (cmux#50983, 2026-11-22: "this text over text thing due to the glass thing keeps
// happening ... i can't read anything"). A menu or popover opened from a composer lies over the
// composer's own text, its chip rows and whatever the page shows under it (a dialog, a suggestion
// list). As glass it let all of that read through its rows: the page's tint covers only part of
// what is under it, the App's host glass is drawn under the whole page (so the page's own text
// above that glass stays crisp unless the page blurs it in place), and a surface over the composer
// may not blur the composer at all (seeThroughBlur.ts keepUnderlayOver). Every one of those paths
// failed somewhere: the folder picker over the composer, the permission picker over New Tab's
// suggestions, both over the Use cmux Tools dialog.
//
// So a popup opened inside a <SolidPopups> subtree (the chat composer and New Tab's screen) is
// solid: it lays the opaque popup surface (--glass-opaque, the Reduce Transparency fill) under its
// rows in every engine and glass mode, takes no backdrop blur and asks the App for no host glass
// (glass.css SOLID POPUPS). Its rim and drop stay. React context crosses portals, so a menu Base UI
// portals out of the composer still knows it was opened there.
//
// One popup at a time: a list that follows the field (New Tab's suggestions, the composer's / and @
// lists) yields while any other solid popup is open (`useYieldsToPopup`), so a chip's menu never
// opens over a list still standing under it.
import { createContext, use, useLayoutEffect, useState, type ReactNode } from "react";

/** On a popup surface opened inside <SolidPopups>: glass.css draws it opaque, with no blur. */
export const SOLID_POPUP_ATTRIBUTE = "data-popup-solid";
/** On a solid popup that gives way to any other (`useYieldsToPopup`): a list that follows the field. */
export const YIELDING_POPUP_ATTRIBUTE = "data-popup-yields";

const SolidPopupsContext = createContext(false);

/** Popups opened anywhere inside are solid (the composer, New Tab's screen). */
export function SolidPopups({ children }: { children: ReactNode }) {
  return <SolidPopupsContext value={true}>{children}</SolidPopupsContext>;
}

/** Whether a popup rendered here is solid. */
export function useSolidPopups(): boolean {
  return use(SolidPopupsContext);
}

type SurfaceAttributes = {
  [SOLID_POPUP_ATTRIBUTE]?: "";
  [YIELDING_POPUP_ATTRIBUTE]?: "";
  "data-host-glass"?: "menu" | "popover";
  "data-host-glass-cover"?: "";
};

/** The attributes a popup surface carries: a solid one is marked so and asks for no host glass
 * (the App's glass would only sit unseen under its fill); any other keeps its host glass level. */
export function popupSurfaceAttributes(
  solid: boolean,
  level: "menu" | "popover",
  hostGlass = true,
  yields = false,
): SurfaceAttributes {
  if (solid) return yields ? { [SOLID_POPUP_ATTRIBUTE]: "", [YIELDING_POPUP_ATTRIBUTE]: "" } : { [SOLID_POPUP_ATTRIBUTE]: "" };
  return hostGlass ? { "data-host-glass": level, "data-host-glass-cover": "" } : {};
}

/** The attributes for a popup a feature draws itself (a list, a picker): solid inside <SolidPopups>. */
export function useSolidPopupAttributes(options?: { yields?: boolean }): Record<string, string> {
  const solid = useSolidPopups();
  if (!solid) return {};
  return options?.yields ? { [SOLID_POPUP_ATTRIBUTE]: "", [YIELDING_POPUP_ATTRIBUTE]: "" } : { [SOLID_POPUP_ATTRIBUTE]: "" };
}

const OTHER_POPUP = `[${SOLID_POPUP_ATTRIBUTE}]:not([${YIELDING_POPUP_ATTRIBUTE}], [data-ending-style], [hidden])`;

/** Whether a solid popup other than a yielding list is open in `doc`. */
export function anotherPopupOpen(doc: Document): boolean {
  for (const element of doc.querySelectorAll(OTHER_POPUP)) if (element.isConnected) return true;
  return false;
}

/** While `active`, whether a popup that does not yield (a chip's menu, a picker) is open in the
 * document: the caller's list hides then, so only one popup stands at a time. One MutationObserver
 * while active (added and removed nodes, and the close fade's attribute), none otherwise. */
export function useYieldsToPopup(active: boolean, doc: Document | null | undefined): boolean {
  const [other, setOther] = useState(false);
  useLayoutEffect(() => {
    if (!active || !doc) {
      setOther(false);
      return;
    }
    const check = () => setOther(anotherPopupOpen(doc));
    check();
    const View = doc.defaultView?.MutationObserver;
    if (!View) return;
    const observer = new View(check);
    observer.observe(doc.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["data-ending-style", "hidden", SOLID_POPUP_ATTRIBUTE],
    });
    return () => observer.disconnect();
  }, [active, doc]);
  return active && other;
}
