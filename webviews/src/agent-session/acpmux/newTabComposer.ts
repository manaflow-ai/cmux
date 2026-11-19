import { createContext } from "react";

/// True on the New Tab page (newtab/NewTabScreen.tsx). Its composer sits high on the page, so the
/// chips' menus (mode, model, effort, options) open down. They also drop the 1 to 9 key hints (the
/// keys still pick), and the model menu shows More models in place (QuickModelMenu.tsx).
/// New Tab uses the standard composer controls in gallery previews as well.
export const OnNewTab = createContext(false);
