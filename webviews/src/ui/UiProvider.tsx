// The root every page wraps its React tree in (plans/cmux-next/a11y-foundation.md, rules 3 and 2):
// - overlays (menus, popovers, tooltips, dialogs) portal into the page's own container, never into
//   `document.body`, so the page's theme variables, styles and focus scope apply;
// - the text direction comes from the page's resolved language, so arrow keys follow it.
import { createContext, use, type ReactNode } from "react";
import type { PopupHost } from "./popupHost";
import { DirectionProvider } from "@base-ui/react/direction-provider";
import { isRtlLanguage } from "../pages/shared/i18n";

export type UiDirection = "ltr" | "rtl";

/** How menus and popovers are placed: "absolute" (Base UI's default) or "fixed". */
export type UiOverlayPosition = "absolute" | "fixed";

interface UiContextValue {
  container: HTMLElement | null;
  dir: UiDirection;
  overlayPosition: UiOverlayPosition;
  popupHost: PopupHost | null;
}

const UiContext = createContext<UiContextValue>({
  container: null,
  dir: "ltr",
  overlayPosition: "absolute",
  popupHost: null,
});

/** The text direction of `language` ("ar", "en", "zh-Hans", ...). */
export function languageDirection(language: string): UiDirection {
  return isRtlLanguage(language) ? "rtl" : "ltr";
}

export interface UiProviderProps {
  /** Where overlays render: the page's root element (or an island's own container). */
  container: HTMLElement | null;
  dir?: UiDirection;
  /** "fixed" on a page whose document never scrolls: an open menu follows its anchor in the
   * page's scroller without growing the document (Settings, cx-jh7kq). */
  overlayPosition?: UiOverlayPosition;
  /** Where a menu with no room in the page goes past the window's edge (popupHost.ts); none keeps
   * every menu in the page (Settings). */
  popupHost?: PopupHost | null;
  children: ReactNode;
}

export function UiProvider({
  container,
  dir = "ltr",
  overlayPosition = "absolute",
  popupHost = null,
  children,
}: UiProviderProps) {
  return (
    <UiContext value={{ container, dir, overlayPosition, popupHost }}>
      <DirectionProvider direction={dir}>{children}</DirectionProvider>
    </UiContext>
  );
}

/** The page container overlays portal into (undefined outside a provider: Base UI's default). */
export function usePortalContainer(): HTMLElement | undefined {
  return use(UiContext).container ?? undefined;
}

/** The page's host for menus past the window's edge, if it has one (UiProviderProps.popupHost). */
export function usePopupHost(): PopupHost | null {
  return use(UiContext).popupHost;
}

/** How this page's menus and popovers are placed (UiProviderProps.overlayPosition). */
export function useOverlayPosition(): UiOverlayPosition {
  return use(UiContext).overlayPosition;
}

export function useUiDirection(): UiDirection {
  return use(UiContext).dir;
}
