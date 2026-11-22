// GitHub's own rendering of a body (`bodyHTML`, GitHubPullRequestDetails.swift), drawn the way
// github.com draws it (Leo, 2026-11-07: "is it possible to, like, just add the rendering for the
// links or whatever? Some of this is quite weird"): a bot's badge is its picture, `<details>` folds,
// `<sup>` is small. GitHub has already rendered the Markdown and sanitized the HTML in it; the page
// still trusts none of it. The HTML is parsed into an inert document (DOMParser runs no script and
// loads nothing), then rebuilt as React elements from an allowlist, so the page never sets HTML:
// - kept: text and the structure GitHub's own allowlist emits (paragraphs, headings, lists, quotes,
//   code, tables, details and summary, dl, sup and sub, kbd, line breaks, rules, emphasis);
// - a link opens through the host only when it is https, on the person's click;
// - an image loads only from GitHub's image proxy (camo) and its attachment hosts, the page CSP's
//   own list, or inline (`data:image/...`); any other is its alt text or nothing;
// - `<picture>` keeps its light and dark sources, so the scheme in use picks one, as on github.com;
// - `<details>` starts folded, whatever the body says;
// - every attribute but those named here is dropped (no class, style, id or event handler), and
//   script, style, forms, frames, embeds and SVG are dropped with their contents.
import { Fragment, type ReactNode } from "react";
import { Link, openableLink, type Open } from "./githubLink";

/** The hosts GitHub serves a body's images from (PageDescriptor.githubImageSources). */
const IMAGE_HOSTS = new Set([
  "camo.githubusercontent.com",
  "private-user-images.githubusercontent.com",
  "user-images.githubusercontent.com",
  "avatars.githubusercontent.com",
]);

/** Elements drawn as themselves (their allowed attributes are read per tag below). */
const KEEP = new Set([
  "p",
  "div",
  "span",
  "br",
  "hr",
  "blockquote",
  "pre",
  "code",
  "kbd",
  "samp",
  "var",
  "strong",
  "b",
  "em",
  "i",
  "u",
  "del",
  "s",
  "ins",
  "mark",
  "small",
  "sup",
  "sub",
  "abbr",
  "q",
  "cite",
  "ul",
  "ol",
  "li",
  "dl",
  "dt",
  "dd",
  "details",
  "summary",
  "table",
  "thead",
  "tbody",
  "tfoot",
  "tr",
  "th",
  "td",
  "caption",
  "colgroup",
  "col",
]);

/** Elements dropped with everything in them. */
const DROP = new Set([
  "script",
  "style",
  "template",
  "noscript",
  "iframe",
  "frame",
  "frameset",
  "object",
  "embed",
  "applet",
  "form",
  "button",
  "textarea",
  "select",
  "option",
  "svg",
  "math",
  "canvas",
  "video",
  "audio",
  "link",
  "meta",
  "base",
  "head",
  "title",
]);

/** Parents whose whitespace text React must not draw (it is not allowed there). */
const NO_TEXT = new Set(["table", "thead", "tbody", "tfoot", "tr", "colgroup", "ul", "ol", "dl", "picture", "details"]);

/** How deep the rebuild goes; below this an element is its text, so a body of thousands of nested
 * tags cannot run the stack out. GitHub's own bodies nest a few levels. */
const MAX_DEPTH = 48;

/** An inline image the page's `img-src data:` already allows; it fetches and runs nothing. */
const DATA_IMAGE = /^data:image\/(png|gif|jpeg|webp|svg\+xml)[;,]/i;

/** `url` when the page may load it as an image: https on one of GitHub's image hosts, or an
 * inline image. */
export function imageSource(url: string | null | undefined): string | undefined {
  if (!url) return undefined;
  if (DATA_IMAGE.test(url)) return url;
  try {
    const parsed = new URL(url);
    return parsed.protocol === "https:" && IMAGE_HOSTS.has(parsed.hostname) && !parsed.username && !parsed.password
      ? parsed.href
      : undefined;
  } catch {
    return undefined;
  }
}

/** A `srcset`'s candidates kept only when every URL in it may load. */
function imageSourceSet(value: string | null): string | undefined {
  if (!value) return undefined;
  const candidates = value
    // Candidates part at a comma and a space; a data URL's own comma has none after it.
    .split(/,\s+/)
    .map((candidate) => candidate.trim())
    .filter(Boolean);
  const kept: string[] = [];
  for (const candidate of candidates) {
    const [url, descriptor, ...rest] = candidate.split(/\s+/);
    const source = imageSource(url);
    if (!source || rest.length || (descriptor && !/^\d+(\.\d+)?[wx]$/.test(descriptor))) return undefined;
    kept.push(descriptor ? `${source} ${descriptor}` : source);
  }
  return kept.length ? kept.join(", ") : undefined;
}

/** A width or height attribute as a number of pixels, nothing else. */
function size(value: string | null): number | undefined {
  if (!value || !/^\d{1,4}$/.test(value.trim())) return undefined;
  return Number(value);
}

/** A body's headings sit under the page's own: h3 and below, as GitHubMarkdown draws them. */
function headingTag(name: string): "h3" | "h4" | "h5" | "h6" {
  return `h${Math.min(6, Math.max(3, Number(name.slice(1)) + 2))}` as "h3";
}

function image(element: Element, key: number): ReactNode {
  // GitHub's responsive images: a srcset whose every candidate may load is kept, and an image with
  // only a srcset loads its first candidate (review of #38075, F2).
  const srcSet = imageSourceSet(element.getAttribute("srcset"));
  const src = imageSource(element.getAttribute("src")) ?? srcSet?.split(/,\s+/)[0]?.split(/\s+/)[0];
  const alt = element.getAttribute("alt") ?? "";
  // An image off GitHub's proxy is its alt text, or nothing (a tracking pixel has none).
  if (!src) return alt ? <span key={key}>{alt}</span> : null;
  return (
    <img
      key={key}
      className="gh-md-img"
      src={src}
      srcSet={srcSet}
      alt={alt}
      width={size(element.getAttribute("width"))}
      height={size(element.getAttribute("height"))}
      loading="lazy"
      decoding="async"
      referrerPolicy="no-referrer"
      draggable={false}
    />
  );
}

/** `<picture>`: its prefers-color-scheme sources and its fallback image, nothing else. */
function picture(element: Element, key: number): ReactNode {
  const sources: ReactNode[] = [];
  let fallback: ReactNode = null;
  for (const child of element.children) {
    const name = child.localName;
    if (name === "source") {
      const media = child.getAttribute("media")?.trim() ?? "";
      const srcSet = imageSourceSet(child.getAttribute("srcset"));
      if (srcSet && /^\(prefers-color-scheme:\s*(dark|light)\)$/.test(media)) {
        sources.push(<source key={sources.length} media={media} srcSet={srcSet} />);
      }
    } else if (name === "img") {
      fallback = image(child, 0);
    }
  }
  // No image GitHub's proxy serves: its alt text alone, and no source loads.
  if (!fallback || (fallback as { type?: unknown }).type !== "img") return fallback;
  return (
    <picture key={key}>
      {sources}
      {fallback}
    </picture>
  );
}

function children(element: Element, open: Open, depth: number): ReactNode[] {
  const out: ReactNode[] = [];
  const quiet = NO_TEXT.has(element.localName);
  element.childNodes.forEach((child, index) => {
    const drawn = node(child, index, open, quiet, depth + 1);
    if (drawn != null && drawn !== false) out.push(drawn);
  });
  return out;
}

function node(child: ChildNode, key: number, open: Open, quiet: boolean, depth: number): ReactNode {
  if (child.nodeType === 3) {
    const text = child.textContent ?? "";
    return quiet && !text.trim() ? null : text;
  }
  if (child.nodeType !== 1) return null;
  // Too deep: its text alone, read without recursion.
  if (depth > MAX_DEPTH) return quiet ? null : (child.textContent ?? "");
  return element(child as Element, key, open, depth);
}

function element(el: Element, key: number, open: Open, depth: number): ReactNode {
  const name = el.localName;
  if (DROP.has(name)) return null;
  switch (name) {
    case "a": {
      // A heading's own anchor (`a.anchor`, its octicon) is github.com chrome, not the body.
      if (el.classList.contains("anchor") && !el.textContent?.trim()) return null;
      const href = el.getAttribute("href") ?? "";
      const inner = children(el, open, depth);
      return openableLink(href) ? (
        <Link key={key} href={href} open={open}>
          {inner}
        </Link>
      ) : (
        <Fragment key={key}>{inner}</Fragment>
      );
    }
    case "img":
      return image(el, key);
    case "picture":
      return picture(el, key);
    case "input": {
      // A task list's box (GitHub draws it disabled); anything else is a form control.
      if (el.getAttribute("type") !== "checkbox") return null;
      return <span key={key} className="gh-md-task" aria-hidden="true" />;
    }
    case "h1":
    case "h2":
    case "h3":
    case "h4":
    case "h5":
    case "h6": {
      const Tag = headingTag(name);
      return <Tag key={key}>{children(el, open, depth)}</Tag>;
    }
    case "table":
      return (
        <div key={key} className="gh-md-table">
          <table>{children(el, open, depth)}</table>
        </div>
      );
    case "li": {
      const box = el.querySelector(":scope > input[type=checkbox], :scope > p > input[type=checkbox]");
      return (
        <li key={key} data-task={box ? (box.hasAttribute("checked") ? "done" : "open") : undefined}>
          {children(el, open, depth)}
        </li>
      );
    }
    case "ol": {
      const start = size(el.getAttribute("start"));
      return (
        <ol key={key} start={start}>
          {children(el, open, depth)}
        </ol>
      );
    }
    case "th":
    case "td": {
      const Tag = name;
      const align = el.getAttribute("align");
      const span = (attribute: string) => {
        const value = size(el.getAttribute(attribute));
        return value && value <= 100 ? value : undefined;
      };
      return (
        <Tag
          key={key}
          colSpan={span("colspan")}
          rowSpan={span("rowspan")}
          style={align === "left" || align === "center" || align === "right" ? { textAlign: align } : undefined}
        >
          {children(el, open, depth)}
        </Tag>
      );
    }
    case "details":
      // Folded at first, as a bot's long "Prompt for AI Agents" is on github.com.
      return <details key={key}>{children(el, open, depth)}</details>;
    case "br":
      return <br key={key} />;
    case "hr":
      return <hr key={key} />;
    case "col":
      return <col key={key} />;
    default: {
      if (!KEEP.has(name)) return <Fragment key={key}>{children(el, open, depth)}</Fragment>;
      const Tag = name as "p";
      return <Tag key={key}>{children(el, open, depth)}</Tag>;
    }
  }
}

/** `html` (GitHub's rendering of a body) as React elements, or null when this page cannot parse it. */
export function githubHTML(html: string, open: Open): ReactNode[] | null {
  if (typeof DOMParser === "undefined") return null;
  const doc = new DOMParser().parseFromString(`<body>${html}</body>`, "text/html");
  return children(doc.body, open, 0);
}
