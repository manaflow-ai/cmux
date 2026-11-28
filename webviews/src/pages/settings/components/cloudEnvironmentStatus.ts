/// A Cloud environment's build status as the string key that names it. Its own module so the Default
/// Image editor reads it without pulling the Cloud Environments card into the page's startup script
/// (lazyCards.test.ts; cards are chunks read with their section, cardModules.tsx).
export const STATUS: Record<string, string> = {
  unbuilt: "settingsPage.cloudEnvironments.status.unbuilt",
  building: "settingsPage.cloudEnvironments.status.building",
  ready: "settingsPage.cloudEnvironments.status.ready",
  stale: "settingsPage.cloudEnvironments.status.stale",
  failed: "settingsPage.cloudEnvironments.status.failed",
};
