// The page's size settings for a case, from its URL: `?scale=1.1` sets the interface scale (Text Size)
// as the App's scale script writes it (DesignSettings.interfaceScaleScript), `?zoom=1.25` the page
// zoom (Cmd +/-). Both lay rows out at fractional heights.
export function applyCaseScale(): void {
  const params = new URLSearchParams(location.search);
  const root = document.documentElement;
  const scale = params.get("scale");
  if (scale) {
    for (const name of [
      "--cmux-interface-scale",
      "--cmux-density-scale",
      "--cmux-density-text-scale",
      "--cmux-row-text-scale",
      "--cmux-row-icon-scale",
    ])
      root.style.setProperty(name, scale);
    window.dispatchEvent(new Event("cmux-ui-scale-change"));
  }
  const zoom = params.get("zoom");
  if (zoom) root.style.zoom = zoom;
}
