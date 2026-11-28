// `CSS.escape` for a selector or `url(#id)` built from a runtime string (a row id, a testid, a React id).
//
// WebKit has `CSS.escape`; jsdom has no `CSS` at all, so a bare `CSS.escape(...)` throws a
// ReferenceError there. Inside an event handler that error is swallowed and the rest of the handler
// never runs: since #50251 a fold click's `CSS.escape` stopped the fold hold before it began and
// transcript-fold-anchor drifted 48 px (expected 418.5, got 370.5), and transcript-copy failed the
// same way (#65355). Every selector built from a runtime string goes through this one function.
// The fallback is the CSSOM spec's serialize-an-identifier algorithm, so it matches the browser's
// own output; it is valid inside quotes (`[data-row-id="…"]`) as well as bare (`#…`).
export function cssEscape(value: string): string {
  const native = typeof CSS === "undefined" ? undefined : CSS.escape;
  if (typeof native === "function") return native.call(CSS, value);
  return serializeIdentifier(value);
}

export function serializeIdentifier(value: string): string {
  let out = "";
  const first = value.charCodeAt(0);
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    if (code === 0) out += "�";
    else if (
      (code >= 0x1 && code <= 0x1f) ||
      code === 0x7f ||
      (index === 0 && code >= 0x30 && code <= 0x39) ||
      (index === 1 && code >= 0x30 && code <= 0x39 && first === 0x2d)
    )
      out += `\\${code.toString(16)} `;
    else if (index === 0 && code === 0x2d && value.length === 1) out += `\\${value.charAt(index)}`;
    else if (
      code >= 0x80 ||
      code === 0x2d ||
      code === 0x5f ||
      (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5a) ||
      (code >= 0x61 && code <= 0x7a)
    )
      out += value.charAt(index);
    else out += `\\${value.charAt(index)}`;
  }
  return out;
}
