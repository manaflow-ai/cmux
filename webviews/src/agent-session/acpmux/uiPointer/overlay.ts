// The UI inspector's overlay (uiPointer.css): the outline on the element under the pointer, the
// label beside it (labelModel.ts) and the hint at the top or bottom edge. All of it lives in one
// fixed host with no pointer events on the document's root, so the page under it neither reflows nor
// loses a hover. The outline and the label move together; the first show of either is instant (no
// fly-in from the corner), later moves follow the motion settings through the stylesheet.
import { translate } from "../i18n";
import { hintEdge, labelFacts, placeLabel, type Box, type LabelDensity, type LabelPlacement } from "./labelModel";

export type UiPointerOverlay = {
  readonly host: HTMLElement;
  /** Outlines `element` and labels it (null hides both); `pointer` is the last pointer position. */
  show(element: Element | null, pointer: { x: number; y: number } | null): void;
  /** Hides the outline and the label, keeping the hint. */
  hide(): void;
  remove(): void;
};

export type OverlayOptions = { density: LabelDensity; placement: LabelPlacement };

const make = (doc: Document, tag: string, className: string, text?: string) => {
  const element = doc.createElement(tag);
  element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
};

function buildHint(doc: Document): HTMLElement {
  const hint = make(doc, "div", "cmux-ui-pointer-hint");
  hint.dataset.cmuxUiPointerHint = "";
  hint.dataset.edge = "top";
  hint.setAttribute("role", "status");
  hint.append(make(doc, "span", "cmux-ui-pointer-hint__text", translate("uiPointer.hint")));
  const keys: [string, Parameters<typeof translate>[0]][] = [
    ["↑↓←→", "uiPointer.keyWalk"],
    ["↩", "uiPointer.keyPick"],
    [translate("uiPointer.keyEsc"), "uiPointer.keyCancel"],
  ];
  const row = make(doc, "span", "cmux-ui-pointer-hint__keys");
  for (const [cap, action] of keys) {
    const key = make(doc, "span", "cmux-ui-pointer-hint__key");
    key.append(make(doc, "kbd", "cmux-ui-pointer-kbd", cap), doc.createTextNode(translate(action)));
    row.append(key);
  }
  hint.append(row);
  return hint;
}

function fillLabel(label: HTMLElement, element: Element, density: LabelDensity) {
  const doc = label.ownerDocument;
  const facts = labelFacts(element);
  const part = (name: string, className: string, text: string) => {
    const span = make(doc, "span", className, text);
    span.dataset.part = name;
    return span;
  };
  const head = make(doc, "div", "cmux-ui-pointer-label__head");
  head.append(part("name", "cmux-ui-pointer-label__name", facts.name));
  if (density !== "compact") head.append(part("selector", "cmux-ui-pointer-label__selector", facts.selector));
  head.append(part("size", "cmux-ui-pointer-label__size", facts.size));
  label.replaceChildren(head);
  label.dataset.density = density;
  if (density === "compact") return;
  const snippet = part("snippet", "cmux-ui-pointer-label__snippet", facts.snippet ?? translate("uiPointer.noText"));
  if (facts.snippet === null) snippet.dataset.empty = "";
  label.append(snippet);
  if (density !== "card") return;
  const styles = make(doc, "div", "cmux-ui-pointer-label__styles");
  styles.dataset.part = "styles";
  const swatch = make(doc, "span", "cmux-ui-pointer-label__swatch");
  swatch.style.setProperty("--cmux-ui-pointer-swatch", facts.color);
  styles.append(swatch, doc.createTextNode([facts.color, facts.font, facts.display].join(" · ")));
  label.append(styles);
}

const boxOf = (rect: DOMRect): Box => ({ x: rect.x, y: rect.y, width: rect.width, height: rect.height });

/** Shows `element`; true when it was hidden until now (its first place then takes no transition). */
function reveal(element: HTMLElement): boolean {
  const appearing = element.hidden !== false;
  if (appearing) element.dataset.instant = "";
  element.hidden = false;
  return appearing;
}

/** After an instant first place: commit it, so later moves animate again. */
function settle(element: HTMLElement, appearing: boolean) {
  if (!appearing) return;
  void element.offsetWidth;
  delete element.dataset.instant;
}

export function createOverlay(doc: Document, options: OverlayOptions): UiPointerOverlay {
  const host = make(doc, "div", "cmux-ui-pointer");
  host.dataset.cmuxUiPointer = "";
  const outline = make(doc, "div", "cmux-ui-pointer-outline");
  outline.dataset.cmuxUiPointerOutline = "";
  outline.hidden = true;
  const label = make(doc, "div", "cmux-ui-pointer-label");
  label.dataset.cmuxUiPointerLabel = "";
  label.hidden = true;
  const hint = buildHint(doc);
  host.append(outline, label, hint);
  doc.documentElement.append(host);
  let labelled: Element | null = null;

  const viewport = () => ({ width: doc.documentElement.clientWidth, height: doc.documentElement.clientHeight });
  const placeHint = (obstacles: Box[]) => {
    const edge = hintEdge({ width: hint.offsetWidth, height: hint.offsetHeight }, viewport(), obstacles);
    if (hint.dataset.edge !== edge) hint.dataset.edge = edge;
  };

  const overlay: UiPointerOverlay = {
    host,
    show(element, pointer) {
      const obstacles: Box[] = pointer ? [{ x: pointer.x, y: pointer.y, width: 1, height: 1 }] : [];
      if (!element) {
        overlay.hide();
        placeHint(obstacles);
        return;
      }
      const target = boxOf(element.getBoundingClientRect());
      const outlineAppearing = reveal(outline);
      outline.style.translate = `${target.x}px ${target.y}px`;
      outline.style.width = `${target.width}px`;
      outline.style.height = `${target.height}px`;
      if (element !== labelled) fillLabel(label, element, options.density);
      labelled = element;
      const labelAppearing = reveal(label);
      const size = { width: label.offsetWidth, height: label.offsetHeight };
      const placed = placeLabel(target, size, viewport(), options.placement);
      label.dataset.side = placed.side;
      label.style.translate = `${placed.x}px ${placed.y}px`;
      settle(outline, outlineAppearing);
      settle(label, labelAppearing);
      placeHint([...obstacles, target, { x: placed.x, y: placed.y, ...size }]);
    },
    hide() {
      outline.hidden = true;
      label.hidden = true;
      labelled = null;
    },
    remove() {
      host.remove();
    },
  };
  return overlay;
}
