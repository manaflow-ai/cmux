// The page side of test/accent-glass-invariants-N.test.ts: two standing rules, read from the
// computed styles of a rendered gallery stage.
//
//   - The accent is never orange. macOS paints its system accent wherever a page asks for it
//     (`AccentColor`, `Highlight`, `-webkit-focus-ring-color`, a native control's `accent-color:
//     auto`, an `outline: auto` focus ring), and that accent is orange when the person picks orange
//     in System Settings. A page never asks: every accent comes from the host's `--cmux-accent`.
//     A browser cannot be told to use an orange system accent, so the scan resolves each system
//     color keyword in this engine and flags any computed color equal to one, plus any accent-bearing
//     color (focus ring, caret, `accent-color`, a selected or highlighted row) whose hue is orange.
//   - Glass is never opaque. A surface that blurs what is behind it (`backdrop-filter`) and paints
//     an alpha-1 background hides the blur: it is a solid card that pays for glass. Reduce
//     Transparency makes glass solid on purpose, so the test never sets it.
//
// `scanStage` runs inside the page (page.evaluate), so it is self-contained: no imports, no closures.

export type Finding = {
  /** `system-accent`, `orange-accent`, `native-control-accent`, `auto-focus-ring` or `opaque-glass`. */
  rule: string;
  /** A stable description of the element: tag, id and up to three classes. */
  element: string;
  /** The computed property and value that broke the rule. */
  detail: string;
};

/** The baseline key of a finding on one stage (entry and variant). */
export const findingKey = (stage: string, finding: Finding): string => `${stage} ${finding.rule} ${finding.element}`;

/**
 * Scans every element of the stage, or with `focusedOnly` just the focused one (after a Tab).
 * `orangeAllowed`: the stage's theme is on schemas/theme/orange-accent-allowlist.json, so its own
 * orange accent is not a finding (the system-accent and glass rules still hold).
 */
export function scanStage({ focusedOnly, orangeAllowed }: { focusedOnly: boolean; orangeAllowed: boolean }): Finding[] {
  const canvas = document.createElement("canvas").getContext("2d", { willReadFrequently: true })!;
  /** A computed color as [r, g, b, a] (0–255, a 0–1), painted and read back so every syntax
   * (`color(srgb …)`, `oklch(…)`, `color-mix(…)`) resolves the same way; null when it is not a color. */
  const rgba = (value: string): [number, number, number, number] | null => {
    if (!value || value === "none" || value === "auto" || !CSS.supports("color", value)) return null;
    canvas.clearRect(0, 0, 1, 1);
    canvas.fillStyle = value;
    canvas.fillRect(0, 0, 1, 1);
    const [r, g, b, a] = canvas.getImageData(0, 0, 1, 1).data;
    return [r!, g!, b!, a! / 255];
  };
  /** OKLCH chroma and hue (degrees) of an sRGB color. */
  const lch = ([r, g, b]: number[]): { chroma: number; hue: number } => {
    const linear = (channel: number) => {
      const c = channel / 255;
      return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    };
    const [lr, lg, lb] = [linear(r!), linear(g!), linear(b!)];
    const l = Math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
    const m = Math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
    const s = Math.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
    const A = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
    const B = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;
    return { chroma: Math.hypot(A, B), hue: ((Math.atan2(B, A) * 180) / Math.PI + 360) % 360 };
  };
  // Orange: past red (about 29° for system red) and short of yellow (about 95° for system yellow).
  // macOS's orange accent is #ff9500 (64°) and #ff9f0a in dark mode (68°); Clay Orange's clay is 38°.
  const isOrange = (color: [number, number, number, number] | null) => {
    if (!color || color[3] < 0.05) return false;
    const { chroma, hue } = lch(color);
    return !orangeAllowed && chroma >= 0.1 && hue >= 35 && hue <= 78;
  };
  const sameRgb = (a: number[], b: number[]) =>
    Math.abs(a[0]! - b[0]!) + Math.abs(a[1]! - b[1]!) + Math.abs(a[2]! - b[2]!) <= 3;

  // The system colors that carry the OS accent in this engine; the hued ones only, since a gray
  // keyword (some engines' focus ring) would match every gray on the page.
  const probe = document.createElement("div");
  document.body.append(probe);
  const systemColors: { name: string; rgb: number[] }[] = [];
  for (const name of [
    "AccentColor",
    "AccentColorText",
    "Highlight",
    "SelectedItem",
    "-webkit-focus-ring-color",
    "-apple-system-control-accent",
    "-apple-system-selected-content-background",
  ]) {
    if (!CSS.supports("color", name)) continue;
    probe.style.color = name;
    const color = rgba(getComputedStyle(probe).color);
    if (color && lch(color).chroma >= 0.04) systemColors.push({ name, rgb: color });
  }
  probe.remove();

  const describe = (element: Element) => {
    const id = element.id ? `#${element.id}` : "";
    const classes = [...element.classList]
      .slice(0, 3)
      .map((name) => `.${name}`)
      .join("");
    return `${element.tagName.toLowerCase()}${id}${classes}`;
  };
  const visible = (element: Element, style: CSSStyleDeclaration) => {
    if (style.visibility === "hidden" || style.display === "none" || Number(style.opacity) === 0) return false;
    const box = element.getBoundingClientRect();
    return box.width > 0 && box.height > 0;
  };
  const colorsIn = (value: string) =>
    value.match(/(?:rgba?|color|oklch|oklab|lab|lch|hsla?)\([^()]*(?:\([^()]*\)[^()]*)*\)|#[0-9a-f]{3,8}\b/gi) ?? [];
  // A row or control that shows the selection or the keyboard highlight: its fill is an accent.
  const SELECTED =
    '[aria-selected="true"], [aria-current]:not([aria-current="false"]), [aria-checked="true"], [aria-pressed="true"], ' +
    '[data-selected="true"], [data-highlighted], [data-state="checked"], [data-state="on"], [data-active="true"], ' +
    ".is-selected, .is-active, .selected, .active, :checked";
  const COLOR_PROPERTIES = [
    "color",
    "background-color",
    "border-top-color",
    "border-right-color",
    "border-bottom-color",
    "border-left-color",
    "outline-color",
    "text-decoration-color",
    "caret-color",
    "accent-color",
    "fill",
    "stroke",
    "box-shadow",
  ] as const;

  const findings: Finding[] = [];
  const seen = new Set<string>();
  const add = (rule: string, element: Element, detail: string) => {
    const key = `${rule} ${describe(element)}`;
    if (seen.has(key)) return;
    seen.add(key);
    findings.push({ rule, element: describe(element), detail });
  };

  const elements: Element[] = [];
  const collect = (root: Document | ShadowRoot) => {
    for (const element of root.querySelectorAll("*")) {
      elements.push(element);
      if (element.shadowRoot) collect(element.shadowRoot);
    }
  };
  collect(document);
  if (focusedOnly) {
    let active = document.activeElement;
    while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
    elements.splice(0, elements.length, ...(active && active !== document.body ? [active] : []));
  }

  for (const element of elements) {
    // A theme's preview ball paints that theme's own palette, not an accent of the page.
    if (element.closest("[data-theme-ball]")) continue;
    const style = getComputedStyle(element);
    if (!visible(element, style)) continue;
    const selected = element.matches(SELECTED);

    for (const property of COLOR_PROPERTIES) {
      if (property === "outline-color" && (style.outlineStyle === "none" || parseFloat(style.outlineWidth) === 0))
        continue;
      const value = style.getPropertyValue(property);
      for (const text of property === "box-shadow" ? colorsIn(value) : [value]) {
        const color = rgba(text);
        if (!color || color[3] < 0.05) continue;
        const system = systemColors.find((candidate) => sameRgb(candidate.rgb, color));
        if (system) add("system-accent", element, `${property}: ${value} is ${system.name}`);
        const accentBearing =
          property === "outline-color" ||
          property === "caret-color" ||
          property === "accent-color" ||
          (selected && property !== "color" && property !== "text-decoration-color");
        if (accentBearing && isOrange(color)) add("orange-accent", element, `${property}: ${value}`);
      }
    }

    // A native checkbox, radio, slider, progress bar or meter draws in the system accent unless
    // the page names its `accent-color` or draws the control itself.
    const native =
      element instanceof HTMLInputElement
        ? ["checkbox", "radio", "range", "color", "date", "datetime-local", "time"].includes(element.type)
        : element instanceof HTMLProgressElement || element instanceof HTMLMeterElement;
    const appearance = style.getPropertyValue("appearance") || style.getPropertyValue("-webkit-appearance");
    if (native && appearance !== "none" && style.accentColor === "auto")
      add("native-control-accent", element, "accent-color: auto");

    // `outline: auto` is the engine's focus ring, which WebKit draws in the system accent.
    if (element.matches(":focus-visible"))
      if (style.outlineStyle === "auto") add("auto-focus-ring", element, `outline: ${style.outline}`);

    const backdrop = style.getPropertyValue("backdrop-filter") || style.getPropertyValue("-webkit-backdrop-filter");
    if (backdrop && backdrop !== "none") {
      const fill = rgba(style.backgroundColor);
      if (fill && fill[3] >= 0.999)
        add("opaque-glass", element, `background-color: ${style.backgroundColor} under backdrop-filter: ${backdrop}`);
    }
  }

  // The page's text selection: the UA's default is the system highlight.
  for (const element of [
    ...(focusedOnly ? [] : [document.body]),
    ...elements.filter((element) => element.matches("[contenteditable], textarea, input")),
  ]) {
    const selection = rgba(getComputedStyle(element, "::selection").backgroundColor);
    if (!selection || selection[3] < 0.05) continue;
    const system = systemColors.find((candidate) => sameRgb(candidate.rgb, selection));
    if (system) add("system-accent", element, `::selection background is ${system.name}`);
    if (isOrange(selection)) add("orange-accent", element, `::selection background ${selection.join(",")}`);
  }
  return findings;
}
