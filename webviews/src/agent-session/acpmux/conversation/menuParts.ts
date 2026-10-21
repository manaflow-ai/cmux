// The part of a message the pointer is on when the native context menu opens (cx-2lm4): a code
// block, a command and its output, a file path or a web link. The message menu reports it
// (messageMenu.ts) and the host adds the part's own items above the message's: Copy Code, Copy
// Command and Copy Output, Open and Copy Path, Open Link and Copy Link. Long texts (code, command
// output) stay off the DOM: a view registers its part on its element with `menuPartRef`.

export type MenuPart = {
  code?: string;
  command?: string;
  output?: string;
  path?: string;
  line?: string;
  link?: string;
};

const parts = new WeakMap<Element, MenuPart>();

/// A ref callback that registers `part` on the element it is set on.
export function menuPartRef(part: MenuPart) {
  return (element: Element | null) => {
    if (element) parts.set(element, part);
  };
}

/// The innermost part around `target`: a registered element, a path chip or file row
/// (`data-path`) or an http(s) link. Undefined elsewhere.
export function menuPartAt(target: Element | null): MenuPart | undefined {
  for (let element = target; element; element = element.parentElement) {
    const part = parts.get(element);
    if (part) return part;
    const path = element.getAttribute("data-path");
    if (path)
      return { path, ...(element.getAttribute("data-line") ? { line: element.getAttribute("data-line")! } : {}) };
    if (element instanceof HTMLAnchorElement && /^https?:\/\//i.test(element.href)) return { link: element.href };
  }
  return undefined;
}
