/** Serializable measurement expressions: all expected lengths resolve in the rendered surface. */
export type GridMetric =
  | "left"
  | "right"
  | "top"
  | "bottom"
  | "cx"
  | "cy"
  | "width"
  | "height"
  | "text"
  | "optical"
  | "radius"
  | "padding"
  | "padding-top"
  | "padding-bottom";
export type GridPoint = {
  selector: string;
  metric: GridMetric;
  /** Prefer the surface's ink role; selector remains the migration fallback. */
  role?: string;
  /** Cross-surface references (composer edges / transcript column) use document scope. */
  scope?: "surface" | "document";
  glyph?: string;
};
export type GridLine = {
  name: string;
  all?: boolean;
  /** Measure inward from a trailing/bottom origin instead of outward from the lead. */
  inward?: boolean;
  actual: GridPoint;
  origin?: GridPoint;
  expected: string | GridPoint;
};
export type GridScene = {
  surface: string;
  level: "warn" | "fail";
  entry: string;
  variant: string;
  root: string;
  rootRole?: string;
  params?: Record<string, string | number>;
  /** Source-audited absences; unknown missing selectors are fixture coverage failures. */
  absent?: Record<string, string>;
  lines: GridLine[];
  textIncludes?: { selector: string; text: string };
};
export type GridResult = {
  line: string;
  expected: number | null;
  actual: number | null;
  delta: number | null;
  diagnostic?: string;
  coverageFailure?: boolean;
};

/** Runs in Chromium. No imported closures, guessed font ascent, or line-box text centers. */
export function measureGridLines(scene: GridScene): GridResult[] {
  const visible = (el: Element) => {
    const style = getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return style.visibility === "visible" && style.display !== "none" && rect.width > 0 && rect.height > 0;
  };
  const roleSelector = (role: string) => `[data-grid-role="${CSS.escape(role)}"]`;
  const roleRoots = scene.rootRole ? [...document.querySelectorAll(roleSelector(scene.rootRole))].filter(visible) : [];
  const roots = roleRoots.length ? roleRoots : [...document.querySelectorAll(scene.root)].filter(visible);
  if (!roots.length) throw new Error(`missing mounted surface ${scene.root}`);
  return roots.flatMap((root, index) => {
    const matches = ({ selector, role, scope }: Pick<GridPoint, "selector" | "role" | "scope">): Element[] => {
      const within = scope === "document" ? document : root;
      if (role) {
        const query = roleSelector(role);
        const marked = [
          ...(within instanceof Element && within.matches(query) ? [within] : []),
          ...within.querySelectorAll(query),
        ].filter(visible);
        if (marked.length) return marked;
      }
      return (
        selector === ":scope"
          ? [root]
          : [
              ...(within instanceof Element && within.matches(selector) ? [within] : []),
              ...within.querySelectorAll(selector),
            ]
      ).filter(visible);
    };
    const select = (selector: string, role?: string, scope?: GridPoint["scope"]) => {
      const el = matches({ selector, role, scope })[0];
      if (!el || !visible(el)) {
        const reason = scene.absent?.[selector];
        throw new Error(reason ? `design absence: ${selector}: ${reason}` : `missing visible selector ${selector}`);
      }
      return el;
    };
    const metric = ({ selector, metric: kind, glyph, role, scope }: GridPoint, selected?: Element): number => {
      const el = selected ?? select(selector, role, scope);
      const offset = (axis: "x" | "y") => {
        if (!glyph) return 0;
        if (!/^[a-z0-9-]+$/.test(glyph)) throw new Error(`invalid optical glyph name ${glyph}`);
        const name = `--grid-optical-${glyph}-${axis}`;
        if (!getComputedStyle(el).getPropertyValue(name).trim()) return 0;
        const probe = document.createElement("span");
        probe.style.cssText =
          "position:absolute;visibility:hidden;display:block;width:0;height:0;margin:0;padding:0;border:0";
        // Translation preserves signed lengths; width would clamp a negative optical offset.
        probe.style.setProperty(name, getComputedStyle(el).getPropertyValue(name));
        root.append(probe);
        try {
          const start = probe.getBoundingClientRect();
          probe.style.transform = `translate${axis.toUpperCase()}(var(${name}))`;
          const end = probe.getBoundingClientRect();
          return axis === "x" ? end.left - start.left : end.top - start.top;
        } finally {
          probe.remove();
        }
      };
      const box = el.getBoundingClientRect();
      const rect = new DOMRect(box.left - offset("x"), box.top - offset("y"), box.width, box.height);
      if (kind === "cx") return rect.left + rect.width / 2;
      if (kind === "cy") return rect.top + rect.height / 2;
      if (kind === "radius") return parseFloat(getComputedStyle(el).borderTopLeftRadius);
      if (kind === "padding") return parseFloat(getComputedStyle(el).paddingLeft);
      // A card's block padding, read from style: its 1 px edge may come from a theme colour some
      // galleries leave out, so the inset from the border box is not a stable line.
      if (kind === "padding-top") return parseFloat(getComputedStyle(el).paddingTop);
      if (kind === "padding-bottom") return parseFloat(getComputedStyle(el).paddingBottom);
      if (kind !== "text" && kind !== "optical") return rect[kind];
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      let node: Node | null;
      while ((node = walker.nextNode())) {
        const start = node.textContent?.search(/\S/) ?? -1;
        // Accessibility-hidden placeholders still paint text; measure their ink too.
        if (start < 0 || !node.parentElement || !visible(node.parentElement)) continue;
        const range = document.createRange();
        range.setStart(node, start);
        range.setEnd(node, start + 1);
        const glyph = range.getBoundingClientRect();
        if (!glyph.width || !glyph.height) continue;
        if (kind === "text") return glyph.left;
        const style = getComputedStyle(node.parentElement);
        const context = document.createElement("canvas").getContext("2d");
        if (!context) throw new Error("canvas text metrics unavailable");
        context.font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
        const cap = context.measureText("H").actualBoundingBoxAscent;
        if (!(cap > 0)) throw new Error("font has no measurable H cap height");
        // A zero-size inline block's bottom sits on the actual text baseline. Insert it at
        // the first glyph, so even wrapping rows measure their first line, not their line box.
        const probe = document.createElement("span");
        probe.style.cssText =
          "display:inline-block;width:0;height:0;padding:0;margin:0;border:0;vertical-align:baseline;line-height:0";
        const original = node.textContent!;
        const wrapper = document.createElement("span");
        node.parentNode!.insertBefore(wrapper, node);
        wrapper.append(node);
        range.setStart(node, start);
        range.collapse(true);
        range.insertNode(probe);
        try {
          return probe.getBoundingClientRect().bottom - cap / 2;
        } finally {
          wrapper.replaceWith(node);
          node.textContent = original;
        }
      }
      throw new Error(`missing visible text in ${selector}`);
    };
    const length = (expression: string) => {
      const names = expression.match(/--(?:grid|cmux-menu)-[\w-]+/g) ?? [];
      if (!names.length) throw new Error(`expected expression must use grid/menu tokens: ${expression}`);
      for (const name of names)
        if (!getComputedStyle(root).getPropertyValue(name).trim()) throw new Error(`missing token ${name}`);
      const probe = document.createElement("span");
      probe.style.cssText =
        "position:absolute;visibility:hidden;display:block;box-sizing:content-box;padding:0;border:0;min-width:0;max-width:none;height:0";
      probe.style.width = expression;
      if (!probe.style.width) throw new Error(`invalid length ${expression}`);
      root.append(probe);
      try {
        return probe.getBoundingClientRect().width;
      } finally {
        probe.remove();
      }
    };
    const results = scene.lines.flatMap((line): GridResult[] => {
      const selectedElements = line.all ? matches(line.actual) : [];
      return (selectedElements.length ? selectedElements : [undefined]).map((selected, matchIndex): GridResult => {
        let expected: number | null = null;
        try {
          expected = typeof line.expected === "string" ? length(line.expected) : metric(line.expected);
          const actual =
            (metric(line.actual, selected) - (line.origin ? metric(line.origin) : 0)) * (line.inward ? -1 : 1);
          if (!Number.isFinite(expected) || !Number.isFinite(actual)) throw new Error("non-finite measurement");
          return {
            line: `${index + 1}/${line.name}${line.all ? `/${matchIndex + 1}` : ""}`,
            expected,
            actual,
            delta: actual - expected,
          };
        } catch (error) {
          return {
            line: `${index + 1}/${line.name}${line.all ? `/${matchIndex + 1}` : ""}`,
            expected,
            actual: null,
            delta: null,
            diagnostic: String(error),
            coverageFailure: !String(error).includes("design absence:"),
          };
        }
      });
    });
    if (scene.textIncludes) {
      try {
        const text = select(scene.textIncludes.selector).textContent ?? "";
        if (!text.includes(scene.textIncludes.text))
          throw new Error(`expected text ${JSON.stringify(scene.textIncludes.text)}, got ${JSON.stringify(text)}`);
      } catch (error) {
        results.push({
          line: "fixture-text",
          expected: null,
          actual: null,
          delta: null,
          diagnostic: String(error),
          coverageFailure: !String(error).includes("design absence:"),
        });
      }
    }
    return results;
  });
}
