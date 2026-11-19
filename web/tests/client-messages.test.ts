import { describe, expect, test } from "bun:test";
import { Glob } from "bun";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import enMessages from "../messages/en.json";
import {
  DOCS_CLIENT_SECTIONS,
  docsClientMessages,
  pruneClientMessages,
  sharedClientMessages,
} from "../i18n/client-messages";

describe("client message catalogs", () => {
  test("the shared catalog drops subtree-only namespaces and keeps the dashboard", () => {
    const shared = sharedClientMessages(enMessages);

    expect(shared.docs).toBeUndefined();
    // Read by the download confirmation outside the community route.
    expect(shared.community).toBeDefined();
    expect(shared.dashboard).toBeDefined();
    expect(shared.common).toBeDefined();
    expect(shared.landing).toBeDefined();
    // The docs namespace alone is about half of the catalog.
    const before = JSON.stringify(pruneClientMessages(enMessages)).length;
    const after = JSON.stringify(shared).length;
    expect(after).toBeLessThan(before * 0.55);
  });

  test("the subtree catalog keeps docs for its nested provider", () => {
    const pruned = pruneClientMessages(enMessages);

    expect(pruned.docs).toBeDefined();
    expect(enMessages.docs).toBeDefined();
  });
});

describe("docs client catalog", () => {
  test("keeps only the docs sections client components read", () => {
    const docs = docsClientMessages(enMessages).docs as Record<string, unknown>;

    expect(Object.keys(docs).sort()).toEqual(
      DOCS_CLIENT_SECTIONS.filter((key) => key in enMessages.docs).sort(),
    );
    expect(docs.configuration).toBeUndefined();
    const full = JSON.stringify(pruneClientMessages(enMessages)).length;
    const slim = JSON.stringify(docsClientMessages(enMessages)).length;
    expect(slim).toBeLessThan(full * 0.75);
  });

  test("every docs section a client component reads is in DOCS_CLIENT_SECTIONS", () => {
    // A client component that reads a section missing here throws MISSING_MESSAGE
    // in the browser, so list it in DOCS_CLIENT_SECTIONS.
    const root = join(import.meta.dir, "..", "app");
    const read = new Set<string>();
    for (const rel of new Glob("**/*.tsx").scanSync(root)) {
      const source = readFileSync(join(root, rel), "utf8");
      if (!/^\s*["']use client["']/m.test(source)) continue;
      for (const m of source.matchAll(/useTranslations\(\s*"docs\.([A-Za-z]+)/g)) {
        read.add(m[1]);
      }
      expect(source).not.toMatch(/useTranslations\(\s*"docs"\s*\)/);
    }
    expect(read.size).toBeGreaterThan(0);
    for (const section of read) {
      expect(DOCS_CLIENT_SECTIONS as readonly string[]).toContain(section);
    }
  });
});
