/**
 * Converts rendered docs HTML to Markdown for "Copy page". It reads the DOM the
 * reader sees, so translated text, generated tables, and code all come along
 * without a second source of truth. Only the element types docs pages use are
 * handled; anything else contributes its text.
 */

/** The subset of `Node`/`Element` this converter reads, so tests can fake it. */
export interface MarkdownSourceNode {
  nodeType: number;
  nodeName: string;
  textContent: string | null;
  childNodes: ArrayLike<MarkdownSourceNode>;
  getAttribute?: (name: string) => string | null;
}

const TEXT_NODE = 3;
const ELEMENT_NODE = 1;

function children(node: MarkdownSourceNode): MarkdownSourceNode[] {
  return Array.from(node.childNodes);
}

function attr(node: MarkdownSourceNode, name: string): string | null {
  return node.getAttribute?.(name) ?? null;
}

function isSkipped(node: MarkdownSourceNode): boolean {
  if (attr(node, "data-pagefind-ignore") === "all") return true;
  // Client navigation keeps earlier pages mounted with an inline display:none.
  if (/display:\s*none/i.test(attr(node, "style") ?? "")) return true;
  if (attr(node, "hidden") !== null) return true;
  if (attr(node, "aria-hidden") === "true") return true;
  const tag = node.nodeName.toLowerCase();
  return tag === "svg" || tag === "button" || tag === "script" || tag === "style";
}

/** A backtick run one longer than any inside `text`, so the code cannot close it. */
function backtickFence(text: string, minimum: number): string {
  const longest = Math.max(0, ...(text.match(/`+/g) ?? []).map((run) => run.length));
  return "`".repeat(Math.max(minimum, longest + 1));
}

function inlineCode(text: string): string {
  const fence = backtickFence(text, 1);
  const pad = text.startsWith("`") || text.endsWith("`") ? " " : "";
  return `${fence}${pad}${text}${pad}${fence}`;
}

function codeFence(code: string, lang: string | null): string {
  const fence = backtickFence(code, 3);
  return `${fence}${lang ?? ""}\n${code}\n${fence}`;
}

function collapse(text: string): string {
  return text.replace(/\s+/g, " ");
}

function inline(node: MarkdownSourceNode, origin: string): string {
  if (node.nodeType === TEXT_NODE) return collapse(node.textContent ?? "");
  if (node.nodeType !== ELEMENT_NODE || isSkipped(node)) return "";
  const tag = node.nodeName.toLowerCase();
  const inner = () => children(node).map((c) => inline(c, origin)).join("");
  switch (tag) {
    case "code":
    case "kbd":
      return inlineCode(node.textContent ?? "");
    case "strong":
    case "b": {
      const text = inner().trim();
      return text ? `**${text}**` : "";
    }
    case "em":
    case "i": {
      const text = inner().trim();
      return text ? `*${text}*` : "";
    }
    case "a": {
      const text = inner().trim();
      const href = attr(node, "href");
      if (!href || !text) return text;
      const absolute = href.startsWith("/") ? `${origin}${href}` : href;
      return `[${text}](${absolute})`;
    }
    case "br":
      return "\n";
    default:
      return inner();
  }
}

function list(node: MarkdownSourceNode, origin: string, ordered: boolean, depth: number): string {
  const items = children(node).filter((c) => c.nodeName.toLowerCase() === "li");
  return items
    .map((item, index) => {
      const marker = ordered ? `${index + 1}.` : "-";
      const nested = children(item)
        .filter((c) => ["ul", "ol"].includes(c.nodeName.toLowerCase()))
        .map((c) => list(c, origin, c.nodeName.toLowerCase() === "ol", depth + 1))
        .join("\n");
      const text = children(item)
        .filter((c) => !["ul", "ol"].includes(c.nodeName.toLowerCase()))
        .map((c) => inline(c, origin))
        .join("")
        .trim();
      const line = `${"  ".repeat(depth)}${marker} ${text}`;
      return nested ? `${line}\n${nested}` : line;
    })
    .join("\n");
}

function table(node: MarkdownSourceNode, origin: string): string {
  const rows: string[][] = [];
  const visit = (n: MarkdownSourceNode) => {
    for (const c of children(n)) {
      const tag = c.nodeName.toLowerCase();
      if (tag === "tr") {
        rows.push(
          children(c)
            .filter((cell) => ["th", "td"].includes(cell.nodeName.toLowerCase()))
            .map((cell) => inline(cell, origin).trim().replace(/\|/g, "\\|")),
        );
      } else if (c.nodeType === ELEMENT_NODE) {
        visit(c);
      }
    }
  };
  visit(node);
  if (rows.length === 0) return "";
  const width = Math.max(...rows.map((r) => r.length));
  const pad = (r: string[]) => [...r, ...Array(width - r.length).fill("")];
  const [head, ...body] = rows.map(pad);
  return [
    `| ${head.join(" | ")} |`,
    `| ${head.map(() => "---").join(" | ")} |`,
    ...body.map((r) => `| ${r.join(" | ")} |`),
  ].join("\n");
}

/**
 * `lang` is the code language of the enclosing `[data-code-lang]` frame, so
 * copied fences keep their info string even when the block shows no header.
 */
function blocks(node: MarkdownSourceNode, origin: string, lang: string | null = null): string[] {
  const out: string[] = [];
  let pendingInline = "";
  const flush = () => {
    const text = pendingInline.trim();
    if (text) out.push(text);
    pendingInline = "";
  };

  for (const child of children(node)) {
    if (child.nodeType === TEXT_NODE) {
      pendingInline += collapse(child.textContent ?? "");
      continue;
    }
    if (child.nodeType !== ELEMENT_NODE || isSkipped(child)) continue;
    const tag = child.nodeName.toLowerCase();
    const heading = /^h([1-6])$/.exec(tag);
    if (heading) {
      flush();
      out.push(`${"#".repeat(Number(heading[1]))} ${inline(child, origin).trim()}`);
    } else if (tag === "p") {
      flush();
      const text = inline(child, origin).trim();
      if (text) out.push(text);
    } else if (tag === "pre") {
      flush();
      out.push(codeFence((child.textContent ?? "").replace(/\n$/, ""), lang));
    } else if (tag === "ul" || tag === "ol") {
      flush();
      out.push(list(child, origin, tag === "ol", 0));
    } else if (tag === "table") {
      flush();
      const md = table(child, origin);
      if (md) out.push(md);
    } else if (tag === "blockquote") {
      flush();
      out.push(
        blocks(child, origin, lang)
          .join("\n\n")
          .split("\n")
          .map((line) => `> ${line}`)
          .join("\n"),
      );
    } else if (tag === "hr") {
      flush();
      out.push("---");
    } else if (["div", "section", "article", "aside", "figure", "details", "header", "footer", "main"].includes(tag)) {
      flush();
      out.push(...blocks(child, origin, attr(child, "data-code-lang") ?? lang));
    } else {
      pendingInline += inline(child, origin);
    }
  }
  flush();
  return out;
}

export function docsHtmlToMarkdown(root: MarkdownSourceNode, origin: string): string {
  return `${blocks(root, origin).join("\n\n")}\n`;
}
