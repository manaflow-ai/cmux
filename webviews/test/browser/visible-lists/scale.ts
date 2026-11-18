// The page's size settings for a case, from its URL: `?scale=1.1` sets the interface scale (Text Size)
// as the App's scale script writes it (DesignSettings.interfaceScaleScript), `?zoom=1.25` the page
// zoom (Cmd +/-). Both lay rows out at fractional heights. `window.__setScale("1.25")` changes the
// interface scale while the list is open.
export function applyCaseScale(): void {
  const params = new URLSearchParams(location.search);
  const scale = params.get("scale");
  if (scale) setCaseScale(scale);
  const zoom = params.get("zoom");
  if (zoom) document.documentElement.style.zoom = zoom;
  // A Text Size change while the list is open, as the App makes it.
  (window as unknown as { __setScale(scale: string): void }).__setScale = setCaseScale;
}

function setCaseScale(scale: string): void {
  const root = document.documentElement;
  {
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
}
