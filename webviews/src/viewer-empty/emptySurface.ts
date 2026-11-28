// The diff page's empty state as one lazy chunk: the picker, its styles and the ui wrapper's
// styles (diffSurface.tsx imports this only when the page has no repository).
export { pickDiffConfig } from "./mount";
export { default as viewerEmptyStyles } from "./styles.css?inline";
export { default as uiStyles } from "../ui/ui.css?inline";
