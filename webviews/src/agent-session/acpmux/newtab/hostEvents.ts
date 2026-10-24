// The window events the New Tab page takes its host's places and weather from. Kept apart from
// adoption.ts (React, the New Tab page) so pageHost.ts, which every agent page loads, can raise them
// without loading the New Tab page.

/// The host's open tabs and workspaces changed (AgentPaneView.refreshNewTabPlaces): the old host's
/// script raises it, and pageHost.ts raises it for the page host's `newTabPlaces` event.
export const NEW_TAB_PLACES_EVENT = "acpmux-newtab-places";
/// The weather widget's reading arrived or changed (AgentPaneView.refreshNewTabWeather): the old
/// host's script raises it, and pageHost.ts raises it for the page host's `newTabWeather` event.
export const NEW_TAB_WEATHER_EVENT = "acpmux-newtab-weather";
