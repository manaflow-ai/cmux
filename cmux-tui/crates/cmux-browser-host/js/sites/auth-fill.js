// Credential fill for sites.browserAuth.request, run by the app (not the
// REPL) after the user types into cmux's credential sheet: the body of an
// async function evaluated with WKWebView.callAsyncJavaScript in the agent
// content world of the frame that holds the fields. Arguments: __fields
// ([{ id, marker }]) and __values ({ id: value }). The values go into the
// page's inputs only; the result carries no value.
const found = [];
for (const f of __fields) {
  const el = document.querySelector('[data-cmux-auth="' + String(f.marker).replace(/["\\]/g, "") + '"]');
  if (!el) return { status: "page_changed", field: f.id };
  if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) || el.disabled || el.readOnly) return { status: "locator_invalid", field: f.id };
  found.push([f, el]);
}
for (const [f, el] of found) {
  const value = __values[f.id];
  if (typeof value !== "string") continue;
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
  el.focus();
  setter.call(el, value);
  el.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertReplacementText" }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  el.removeAttribute("data-cmux-auth");
}
return { status: "filled" };
