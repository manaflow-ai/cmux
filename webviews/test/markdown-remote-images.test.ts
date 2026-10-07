// The markdown page asks its host for remote images (diff-host S6, `markdown.remoteImages`): an
// http(s) image goes to `<remoteImageBase><base64url of the URL>` on the page's own origin, so the
// page CSP stays strict; without a base the URL is left as written (the CSP blocks it).
import { describe, expect, test } from "bun:test";
import { remoteImageURL, resolveImageURL } from "../src/pages/markdown/host";

const BASE = "cmux-page://cmux.markdown/__image/";

function decode(url: string): string {
  const encoded = url.slice(BASE.length).replaceAll("-", "+").replaceAll("_", "/");
  const padded = encoded + "=".repeat((4 - (encoded.length % 4)) % 4);
  return new TextDecoder().decode(Uint8Array.from(atob(padded), (c) => c.charCodeAt(0)));
}

describe("remote images through the host", () => {
  test("an http(s) image becomes a same-origin URL the host decodes", () => {
    const url = resolveImageURL("https://example.com/a b.png?x=1&y=ü", "cmux-page://cmux.markdown/__asset/t/", BASE);
    expect(url.startsWith(BASE)).toBe(true);
    expect(url.slice(BASE.length)).not.toContain("/");
    expect(url.slice(BASE.length)).not.toContain("=");
    expect(decode(url)).toBe("https://example.com/a%20b.png?x=1&y=%C3%BC");
  });

  test("without a remote base the URL stays as written; local and data images are unchanged", () => {
    expect(resolveImageURL("http://example.com/x.png", undefined)).toBe("http://example.com/x.png");
    expect(resolveImageURL("img/a.png", "cmux-page://cmux.markdown/__asset/t/", BASE)).toBe(
      "cmux-page://cmux.markdown/__asset/t/img/a.png",
    );
    expect(resolveImageURL("data:image/png;base64,AA", undefined, BASE)).toBe("data:image/png;base64,AA");
    expect(remoteImageURL("not a url", BASE)).toBe("");
  });
});
