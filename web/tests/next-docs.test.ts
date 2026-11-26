import { describe, expect, test } from "bun:test";
import {
  buildLlmsText,
  resolveAgentPageVariant,
} from "../app/lib/agent-page-paths";
import {
  nextDocPage,
  nextDocPages,
  nextDocPublicPath,
} from "../data/next-docs/pages";
import {
  docsChannelUrl,
  docsPathAvailableInChannel,
} from "../app/lib/docs-channel";

describe("cmux-next docs", () => {
  test("includes the Start page and agent prompt", () => {
    const page = nextDocPage("start");
    expect(page?.title).toBe("Start here");
    const textBlocks = page?.body.flatMap((block) =>
      "code" in block && block.lang === "text" ? [block.code] : [],
    );
    expect(textBlocks?.[0]).toContain(
      "https://cmux.com/docs/nightly/next/start.md",
    );
    expect(textBlocks?.[0]).toContain('follow its "If you are an agent" steps');
    expect(page?.body).toContainEqual({ h2: "If you are an agent" });
  });

  test("resolves HTML and Markdown paths in both public URL forms", () => {
    expect(nextDocPublicPath("start")).toBe("/docs/nightly/next/start");
    expect(resolveAgentPageVariant("/docs/nightly/next/start.md")).toMatchObject({
      kind: "page",
      format: "md",
      canonicalPath: "/docs/nightly/next/start",
    });
    expect(resolveAgentPageVariant("/docs/next/start.md")).toMatchObject({
      kind: "page",
      format: "md",
      canonicalPath: "/docs/next/start",
    });
    expect(resolveAgentPageVariant("/docs/next/no-such-page.md")).toBeNull();
  });

  test("points llms.txt at Start before the general description", () => {
    const llms = buildLlmsText("https://cmux.com");
    const start = "https://cmux.com/docs/nightly/next/start.md";
    expect(llms.indexOf(start)).toBeGreaterThan(-1);
    expect(llms.indexOf(start)).toBeLessThan(llms.indexOf("## What cmux is"));
    for (const page of nextDocPages) {
      expect(llms).toContain(`https://cmux.com${nextDocPublicPath(page.slug)}.md`);
    }
  });

  test("keeps NEXT pages in the nightly channel", () => {
    expect(docsPathAvailableInChannel("nightly", "/docs/next/start")).toBe(true);
    expect(docsPathAvailableInChannel("release", "/docs/next/start")).toBe(false);
    expect(docsChannelUrl("nightly", "/docs/next/start")).toBe(
      "/docs/nightly/next/start",
    );
    expect(docsChannelUrl("release", "/docs/nightly/next/start")).toBe(
      "/docs/getting-started",
    );
  });
});
