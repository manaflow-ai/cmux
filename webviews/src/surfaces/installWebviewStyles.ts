/**
 * Injects a webview surface's bundled (inlined) CSS into the document head.
 *
 * Each surface ships its styles as a `?inline` import so the split surface
 * chunk carries its own CSS instead of emitting a separate stylesheet asset.
 * A surface's user stylesheet (`applyUserThemeCSS`) stays after every one of
 * them, so styles loaded on demand later never cover it.
 */
export function installWebviewStyles(id: string, styles: string, doc: Document = document): void {
  // Once per id: the diff empty state installs the viewer styles before the viewer does.
  if (doc.head.querySelector(`style[data-cmux-webview-style="${id}"]`)) return;
  const style = doc.createElement("style");
  style.dataset.cmuxWebviewStyle = id;
  style.textContent = styles;
  doc.head.insertBefore(style, doc.head.querySelector("style[data-cmux-user-theme]"));
}

/**
 * Applies a surface's user stylesheet, `<config dir>/<surface>/theme.css` (customization.md rule 4),
 * as the last `<style>` in the head, replacing the one before; "" clears it.
 */
export function applyUserThemeCSS(surface: string, css: string, doc: Document = document): void {
  let style = doc.head.querySelector<HTMLStyleElement>(`style[data-cmux-user-theme="${surface}"]`);
  if (!style) {
    style = doc.createElement("style");
    style.dataset.cmuxUserTheme = surface;
  }
  style.textContent = css;
  // Last each time, after every stylesheet the page added since.
  doc.head.append(style);
}
