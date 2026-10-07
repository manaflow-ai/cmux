// The gallery's build-time modules (dev-server/galleryHost.ts).
declare module "virtual:cmux-gallery/themes" {
  const themes: import("./theme/ghostty").GhosttyTheme[];
  export default themes;
}
declare module "virtual:cmux-gallery/web-theme" {
  /** WebTheme.bootstrapScript (WebTheme.swift). */
  const script: string;
  export default script;
}
declare module "virtual:cmux-gallery/agent-pane.css";
