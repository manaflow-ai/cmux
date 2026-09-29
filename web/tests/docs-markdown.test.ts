import { describe, expect, test } from "bun:test";
import {
  docsHtmlToMarkdown,
  type MarkdownSourceNode,
} from "../app/lib/docs-markdown";

type Child = MarkdownSourceNode | string;

function text(value: string): MarkdownSourceNode {
  return { nodeType: 3, nodeName: "#text", textContent: value, childNodes: [] };
}

function el(
  tag: string,
  attrs: Record<string, string>,
  ...kids: Child[]
): MarkdownSourceNode {
  const childNodes = kids.map((k) => (typeof k === "string" ? text(k) : k));
  return {
    nodeType: 1,
    nodeName: tag.toUpperCase(),
    get textContent() {
      return childNodes.map((c) => c.textContent ?? "").join("");
    },
    childNodes,
    getAttribute: (name) => attrs[name] ?? null,
  };
}

const origin = "https://cmux.com";

describe("docsHtmlToMarkdown", () => {
  test("converts headings, paragraphs, inline code, and relative links", () => {
    const root = el(
      "div",
      {},
      el("h1", {}, el("a", { "data-pagefind-ignore": "all", href: "#title" }, el("svg", {})), "Getting Started"),
      el("p", {}, "Run ", el("code", {}, "cmux ping"), " then see ", el("a", { href: "/docs/api" }, "the API"), "."),
      el("h2", {}, "Install"),
    );
    expect(docsHtmlToMarkdown(root, origin)).toBe(
      "# Getting Started\n\nRun `cmux ping` then see [the API](https://cmux.com/docs/api).\n\n## Install\n",
    );
  });

  test("keeps code blocks verbatim and drops copy buttons", () => {
    const root = el(
      "div",
      { "data-code-block": "" },
      el("div", {}, el("span", {}, "bash"), el("button", {}, "Copy code")),
      el("pre", {}, el("code", {}, "brew tap manaflow-ai/cmux\nbrew install --cask cmux\n")),
    );
    expect(docsHtmlToMarkdown(el("div", {}, root), origin)).toBe(
      "bash\n\n```\nbrew tap manaflow-ai/cmux\nbrew install --cask cmux\n```\n",
    );
  });

  test("renders nested lists and tables", () => {
    const root = el(
      "div",
      {},
      el("ul", {}, el("li", {}, "One", el("ol", {}, el("li", {}, "Inner"))), el("li", {}, el("strong", {}, "Two"))),
      el(
        "table",
        {},
        el("thead", {}, el("tr", {}, el("th", {}, "Key"), el("th", {}, "Value"))),
        el("tbody", {}, el("tr", {}, el("td", {}, el("code", {}, "a|b")), el("td", {}, "x"))),
      ),
    );
    expect(docsHtmlToMarkdown(root, origin)).toBe(
      "- One\n  1. Inner\n- **Two**\n\n| Key | Value |\n| --- | --- |\n| `a\\|b` | x |\n",
    );
  });
});

describe("docsHtmlToMarkdown hidden pages", () => {
  test("skips pages that client navigation kept mounted but hidden", () => {
    const root = el(
      "div",
      {},
      el("div", { style: "display: none !important;" }, el("h1", {}, "Old page")),
      el("div", { hidden: "" }, el("p", {}, "Hidden")),
      el("div", {}, el("h1", {}, "Current page")),
    );
    expect(docsHtmlToMarkdown(root, origin)).toBe("# Current page\n");
  });
});
