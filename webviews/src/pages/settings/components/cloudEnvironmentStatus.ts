// Each environment status's label key: shared by the card and the default-image editor, kept out of
// CloudEnvironmentsCard so the editor does not pull the card into the page's startup script.
export const STATUS: Record<string, string> = {
  unbuilt: "settingsPage.cloudEnvironments.status.unbuilt",
  building: "settingsPage.cloudEnvironments.status.building",
  ready: "settingsPage.cloudEnvironments.status.ready",
  stale: "settingsPage.cloudEnvironments.status.stale",
  failed: "settingsPage.cloudEnvironments.status.failed",
};
