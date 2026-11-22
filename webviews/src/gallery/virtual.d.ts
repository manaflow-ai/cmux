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
declare module "virtual:cmux-gallery/fixtures" {
  /** Every shared fixture JSON (schemas/gallery/fixtures.json roots), by repo-relative path. */
  const fixtures: Record<string, unknown>;
  export default fixtures;
}
declare module "virtual:cmux-gallery/metrics" {
  /** MetricTunables.swift defaults per density. */
  const metrics: Record<string, { compact: number; comfortable: number }>;
  export default metrics;
}
declare module "virtual:cmux-gallery/revision" {
  /** The commit the gallery was built or served from (git, read when the module loads). */
  const revision: import("./liveStatus").Revision;
  export default revision;
}
