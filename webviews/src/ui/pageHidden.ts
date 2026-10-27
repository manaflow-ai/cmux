// HIDDEN-PAGE LOOPS (p03-rendering-120, feature `hiddenPageLoops`): the app's WebTheme bootstrap
// (`cmuxTheme.visibility`) marks `<html>` while no one can see the page, its tab hidden or its window
// covered or minimized. Under the mark every CSS and script animation is paused and
// animation-frame callbacks wait for the show, as a hidden Chrome tab runs none.

/** On `<html>` while the page is hidden or occluded. */
export const HIDDEN_ATTRIBUTE = "data-cmux-hidden";
/** Fired on the document after the mark comes or goes. */
export const HIDDEN_EVENT = "cmux-visibility";

/** Whether no one can see `doc`: its engine hides it (`visibilityState`) or the host marked it. */
export function documentHidden(doc: Pick<Document, "visibilityState" | "documentElement">): boolean {
  return doc.visibilityState === "hidden" || doc.documentElement?.hasAttribute(HIDDEN_ATTRIBUTE) === true;
}
