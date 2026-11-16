// The markup of the svg <Icon> draws, as a string, for a CSS mask image: the same viewBox and the same
// children iconLayers.tsx renders (its strokes, knockouts and masks), so the masked element draws the
// same pixels as the inline svg. Layers in the accent color cannot be one mask (it reads only alpha).
import { isValidElement, type ReactElement, type ReactNode } from "react";

/// React's names for the svg attributes iconLayers.tsx writes, as the markup spells them.
const ATTRIBUTES: Record<string, string> = {
  fillRule: "fill-rule",
  strokeWidth: "stroke-width",
  strokeLinecap: "stroke-linecap",
  strokeLinejoin: "stroke-linejoin",
  strokeDasharray: "stroke-dasharray",
  strokeDashoffset: "stroke-dashoffset",
};

const escape = (value: string) => value.replace(/[&"<>]/g, (char) => `&#${char.charCodeAt(0)};`);

/// One element of iconLayers.tsx's output and its children, as markup; currentColor drawn black (a mask
/// reads only alpha).
function markup(node: ReactNode): string {
  if (Array.isArray(node)) return node.map(markup).join("");
  if (!isValidElement(node) || typeof node.type !== "string") return "";
  const { children, ...props } = (node as ReactElement<Record<string, unknown>>).props;
  let attributes = "";
  for (const [name, value] of Object.entries(props)) {
    if (value === undefined || value === null || value === false) continue;
    const text = String(value) === "currentColor" ? "black" : String(value);
    attributes += ` ${ATTRIBUTES[name] ?? name}="${escape(text)}"`;
  }
  return `<${node.type}${attributes}>${markup(children as ReactNode)}</${node.type}>`;
}

/// The svg document for `children` (iconLayers.tsx's output) in `viewBox`.
export function iconMarkup(viewBox: string, children: ReactNode[]): string {
  // l10n-allow: SVG markup for a CSS mask image, never shown as text
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${escape(viewBox)}">${markup(children)}</svg>`;
}
