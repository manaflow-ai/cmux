// The root every page wraps its React tree in (plans/cmux-next/a11y-foundation.md, rules 3 and 2):
// - overlays (menus, popovers, tooltips, dialogs) portal into the page's own container, never into
//   `document.body`, so the page's theme variables, styles and focus scope apply;
// - the text direction comes from the page's resolved language, so arrow keys follow it.
import { createContext, use, type ReactNode } from "react";
import { DirectionProvider } from "@base-ui/react/direction-provider";

export type UiDirection = "ltr" | "rtl";

interface UiContextValue {
  container: HTMLElement | null;
  dir: UiDirection;
}

const UiContext = createContext<UiContextValue>({ container: null, dir: "ltr" });

/** Right-to-left languages among the pages' locales (Apple localization codes or BCP 47 tags). */
const RTL_LANGUAGES = new Set(["ar", "fa", "he", "ur"]);

/** The text direction of `language` ("ar", "en", "zh-Hans", ...). */
export function languageDirection(language: string): UiDirection {
  return RTL_LANGUAGES.has(language.split(/[-_]/)[0].toLowerCase()) ? "rtl" : "ltr";
}

export interface UiProviderProps {
  /** Where overlays render: the page's root element (or an island's own container). */
  container: HTMLElement | null;
  dir?: UiDirection;
  children: ReactNode;
}

export function UiProvider({ container, dir = "ltr", children }: UiProviderProps) {
  return (
    <UiContext value={{ container, dir }}>
      <DirectionProvider direction={dir}>{children}</DirectionProvider>
    </UiContext>
  );
}

/** The page container overlays portal into (undefined outside a provider: Base UI's default). */
export function usePortalContainer(): HTMLElement | undefined {
  return use(UiContext).container ?? undefined;
}

export function useUiDirection(): UiDirection {
  return use(UiContext).dir;
}
