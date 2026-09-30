/**
 * Injects a webview surface's bundled (inlined) CSS into the document head.
 *
 * Each surface ships its styles as a `?inline` import so the split surface
 * chunk carries its own CSS instead of emitting a separate stylesheet asset.
 */
export function installWebviewStyles(id: string, styles: string): void {
  const style = document.createElement("style");
  style.dataset.cmuxWebviewStyle = id;
  style.textContent = styles;
  document.head.append(style);
}
