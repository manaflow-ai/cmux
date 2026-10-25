import { createContext } from "react";

/// True on the New Tab page (newtab/NewTabScreen.tsx). Its composer sits high on the page, so the
/// chips' menus (mode, model, effort, options) open down. They also drop what a new tab has no use
/// for: the "Mode" and "Model · this session" headings and the 1 to 9 key hints (the keys still pick).
export const OnNewTab = createContext(false);
