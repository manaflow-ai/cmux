// What the page reports for a picked element (the native UIInspectorController builds the reference
// the agent receives from these fields; their names and values must not change), and the selector
// the report and the live label (labelModel.ts) share.

/** What the page reports for a picked element: the native controller builds the reference from it. */
export type UiPointerReport = {
  selector: string;
  tag_name: string;
  text_content: string;
  dom_snippet: string;
  component: string | null;
  source_location: string | null;
  bounds: { x: number; y: number; width: number; height: number };
  viewport: { width: number; height: number };
  computed_styles: Record<string, string>;
};

const STYLE_KEYS = [
  "display",
  "position",
  "width",
  "height",
  "margin",
  "padding",
  "font-family",
  "font-size",
  "font-weight",
  "line-height",
  "color",
  "background-color",
  "border-radius",
];

const bounded = (value: unknown, limit: number) => String(value || "").slice(0, limit);

export function selectorOf(element: Element): string {
  if (element.id) return `#${CSS.escape(element.id)}`;
  const testid = element.getAttribute("data-testid");
  if (testid) return `${element.localName}[data-testid="${CSS.escape(testid)}"]`;
  const aria = element.getAttribute("aria-label");
  if (aria) return `${element.localName}[aria-label="${CSS.escape(aria)}"]`;
  return element.localName || "element";
}

/** The component an element belongs to (its nearest `data-cmux-component`), if any. */
export const componentOf = (element: Element): string | null =>
  element.closest("[data-cmux-component]")?.getAttribute("data-cmux-component") || null;

export function reportOf(element: Element): UiPointerReport {
  const view = element.ownerDocument.defaultView ?? window;
  const rect = element.getBoundingClientRect();
  const computed = view.getComputedStyle(element);
  const styles: Record<string, string> = {};
  for (const key of STYLE_KEYS) styles[key] = bounded(computed.getPropertyValue(key), 160);
  return {
    selector: selectorOf(element),
    tag_name: element.localName || "element",
    text_content: bounded((element as HTMLElement).innerText ?? element.textContent, 2000),
    dom_snippet: bounded(element.outerHTML, 2400),
    component: componentOf(element),
    source_location: element.closest("[data-cmux-source]")?.getAttribute("data-cmux-source") || null,
    bounds: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
    viewport: { width: view.innerWidth, height: view.innerHeight },
    computed_styles: styles,
  };
}
