// Keep this leaf independent of the language registry. The highlight worker imports it but
// receives resolved grammars from the page; importing ../index bundles every grammar again.
export function createOnigurumaEngine(): never {
  throw new Error("The agent pane highlights with the JavaScript regex engine only");
}
