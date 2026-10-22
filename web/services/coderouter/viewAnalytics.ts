// When a CodeRouter read counts as a product view.
//
// The native clients fetch the account list, the organization catalog and
// team machine usage on timers and on every auth refresh. Counting each fetch
// as a `coderouter_*_viewed` event produced about 1.3M events per event name
// in two weeks from roughly 100 people, so those reads are not views. A
// client marks the one request it makes when a person actually opens the
// view with this header, and only that request emits the event. The web
// dashboard sends it when a page loads the team catalog; server-rendered
// dashboard reads that do not pass through these routes keep emitting.

export const CODEROUTER_VIEW_OPEN_HEADER = "x-cmux-view-open";

/** True when the client says this request opened a view (not a refresh or poll). */
export function isCoderouterViewOpenRequest(request: Request): boolean {
  return request.headers.get(CODEROUTER_VIEW_OPEN_HEADER)?.trim() === "1";
}
