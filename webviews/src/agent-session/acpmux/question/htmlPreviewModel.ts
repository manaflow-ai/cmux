import { createContext } from "react";

/// How the frame sits in the preview column. `framed` (the default): inside the card's preview
/// box, like a monospace preview. `canvas`: on a page-coloured artboard with an edge, so a mockup
/// with its own background reads as a picture. `bleed`: no box, the picture fills the column.
export type HtmlPreviewLook = "framed" | "canvas" | "bleed";
export const HtmlPreviewLookContext = createContext<HtmlPreviewLook>("framed");

/// The shortest and tallest the picture draws; a taller one scrolls inside the frame.
export const HTML_PREVIEW_MIN_HEIGHT = 80;
export const HTML_PREVIEW_MAX_HEIGHT = 420;

/// What the preview's own document may load: nothing but inline styles and data: images and fonts.
const POLICY =
  "default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; form-action 'none'; base-uri 'none'";

/// Elements dropped whole, by lowercase name.
const DROPPED = new Set([
  // They run, load, embed or navigate.
  ..."script,noscript,template,iframe,frame,frameset,object,embed,applet,portal,meta,base,link,style".split(","),
  // SVG animation: it would set an attribute (a link's href) after the cleaning.
  ..."set,animate,animatemotion,animatetransform,animatecolor,discard".split(","),
]);
/// Attributes that name a URL. Only fragment links and data: URLs stay.
const URL_ATTRIBUTES = ["href", "xlink:href", "src", "action", "formaction", "poster", "background", "ping"];
/// Attributes that list several URLs, any of which could load: always dropped (a `src` is enough).
const URL_LIST_ATTRIBUTES = ["srcset", "imagesrcset"];

/// The frame's whole document: the policy, the pane's theme and base styles (renderBase.ts, the
/// same ones a render card gets), then the cleaned fragment. `theme` is the stylesheet text.
/// `inset` is the picture's margin inside the frame, in px.
export function previewDocument(fragment: string, theme: string, inset = 0): string {
  const parsed = new DOMParser().parseFromString(`<body>${fragment}</body>`, "text/html");
  for (const element of Array.from(parsed.body.querySelectorAll("*"))) {
    // By name, any case: an SVG element keeps its camelCase name (animateMotion).
    if (DROPPED.has(element.localName.toLowerCase())) {
      element.remove();
      continue;
    }
    for (const attribute of Array.from(element.attributes)) {
      const name = attribute.name.toLowerCase();
      if (name.startsWith("on") || URL_LIST_ATTRIBUTES.includes(name)) element.removeAttribute(attribute.name);
      else if (URL_ATTRIBUTES.includes(name) && !/^\s*(#|data:image\/)/i.test(attribute.value))
        element.removeAttribute(attribute.name);
    }
    // A link keeps its look but goes nowhere.
    if (element.localName === "a") element.removeAttribute("target");
  }
  return (
    `<!doctype html><html><head><meta charset="utf-8">` +
    `<meta http-equiv="Content-Security-Policy" content="${POLICY}">` +
    `<style>${theme}:where(body){margin:${inset}px}</style></head><body>${parsed.body.innerHTML}</body></html>`
  );
}
