/// A second folder request while the native chooser is still active stays in its caller.
export type BrowseBusy = { readonly status: "busy" };
export type BrowseResult = string | BrowseBusy | undefined;
export const BROWSE_BUSY: BrowseBusy = { status: "busy" };
export const isBrowseBusy = (value: BrowseResult | void): value is BrowseBusy =>
  typeof value === "object" && value !== null && value.status === "busy";
