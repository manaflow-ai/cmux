import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { safeHref } from "../model";
import { Markdown } from "./Markdown";

// A reply's links are untrusted. Only an absolute http(s) URL without a user name or password is
// a link; anything relative would resolve against the pane's own page and navigate it away.
describe("reply links", () => {
  test("absolute http and https URLs are links", () => {
    expect(safeHref("https://github.com/manaflow-ai/cmux")).toBe("https://github.com/manaflow-ai/cmux");
    expect(safeHref("http://example.com/a?b=1#c")).toBe("http://example.com/a?b=1#c");
    expect(safeHref("HTTPS://Example.com/x")).toBe("https://example.com/x");
  });

  test("relative, scheme-relative, query-only and fragment-only targets are not links", () => {
    for (const href of [
      "README.md",
      "../",
      "../../etc/passwd",
      "?x=1",
      "#top",
      "//evil.example/x",
      "/Users/me/a.ts",
      "",
    ]) {
      expect(safeHref(href)).toBeUndefined();
    }
  });

  test("a URL with a user name or password is not a link", () => {
    expect(safeHref("https://user:pw@example.com/")).toBeUndefined();
    expect(safeHref("https://user@example.com/")).toBeUndefined();
    expect(safeHref("https://:pw@example.com/")).toBeUndefined();
  });

  test("other schemes are not links", () => {
    for (const href of [
      "javascript:alert(1)",
      "data:text/html,x",
      "file:///etc/hosts",
      "cmux://session/x",
      "vbscript:x",
    ]) {
      expect(safeHref(href)).toBeUndefined();
    }
  });

  test("a reply's relative and credential links draw as their text", () => {
    const html = renderToStaticMarkup(
      createElement(
        Markdown,
        null,
        "[readme](README.md) [up](../) [q](?x=1) [host](//evil.example/x) [login](https://u:p@example.com/)",
      ),
    );
    expect(html).not.toContain("<a ");
    for (const text of ["readme", "up", "q", "host", "login"]) expect(html).toContain(text);
  });
});
