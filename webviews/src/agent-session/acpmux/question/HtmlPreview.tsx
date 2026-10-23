// An option preview an agent wrote as HTML (Claude Code launched with
// CLAUDE_CODE_QUESTION_PREVIEW_FORMAT=html: "HTML mockups of UI layouts or components, formatted code
// snippets, visual comparisons or diagrams", a fragment with inline styles and no script or style
// tag). It draws in a frame of its own, never in the pane's document:
// - the frame is sandboxed without scripts, so nothing in the fragment runs (no script, no event
//   handler attribute, no javascript: link), and it cannot submit, open or navigate the pane;
// - its document carries a policy that loads nothing (no network, no remote image or font), on top
//   of the pane's own, which an srcdoc frame inherits;
// - the fragment is cleaned first (`previewDocument`): elements that load or navigate (script,
//   frames, embeds, meta, base, link, SVG animation) are dropped and links lose their targets. The
//   cleaning is a second line: a remote url() in an inline style survives it, and only the
//   policy keeps that from loading.
// The frame shares the pane's origin (allow-same-origin without allow-scripts), only so the card can
// read the picture's height and grow to it, up to a cap past which it scrolls.
import { createContext, useContext, useEffect, useMemo, useRef, useState } from "react";
import { renderFrameCSS } from "../conversation/renderBase";

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

/// The picture's height in the frame, clamped to the card's range.
const clampHeight = (height: number) =>
  Math.min(HTML_PREVIEW_MAX_HEIGHT, Math.max(HTML_PREVIEW_MIN_HEIGHT, Math.ceil(height)));

export function HtmlPreview({ html, title }: { html: string; title: string }) {
  const look = useContext(HtmlPreviewLookContext);
  const frame = useRef<HTMLIFrameElement>(null);
  const [height, setHeight] = useState(HTML_PREVIEW_MIN_HEIGHT);
  // Built once per fragment: the theme is read when that fragment first shows.
  // The canvas look is an artboard with the picture inset on it; the others have no edge to clear.
  const srcDoc = useMemo(() => previewDocument(html, renderFrameCSS(), look === "canvas" ? 12 : 0), [html, look]);
  // The height follows the picture: measured when the frame loads and whenever the frame's width
  // changes (the card or pane resized, which reflows the picture). The picture's own box, not the
  // document's scroll height, which never drops below the frame's current height, so a shorter
  // picture shrinks the frame. Stops with the preview: the observer is disconnected and the load
  // listener removed on unmount or a new fragment.
  useEffect(() => {
    const element = frame.current;
    if (!element) return;
    const measure = () => {
      const root = element.contentDocument?.documentElement;
      if (root) setHeight(clampHeight(root.getBoundingClientRect().height));
    };
    element.addEventListener("load", measure);
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => {
      element.removeEventListener("load", measure);
      observer.disconnect();
    };
  }, [srcDoc]);
  return (
    <iframe
      ref={frame}
      className="acpmux-question-html"
      data-look={look}
      title={title}
      srcDoc={srcDoc}
      // ui-allow: no scripts; same-origin only so the card can read the picture's height.
      sandbox="allow-same-origin"
      referrerPolicy="no-referrer"
      loading="lazy"
      style={{ height }}
    />
  );
}
