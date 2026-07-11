import { describe, expect, mock, test } from "bun:test";

mock.module("next-intl/server", () => ({
  getTranslations: async () => (key: string) =>
    key === "title" ? "cmux — The terminal for AI coding" : key,
}));

const { auditedDocsMetadata } = await import(
  "../app/[locale]/(landing)/docs/audited-docs-metadata"
);

describe("audited docs metadata", () => {
  test("preserves the localized docs layout title template", async () => {
    const pageMessages: Record<string, string> = {
      metaTitle: "CLI Reference",
      title: "CLI Reference",
      metaDescription:
        "Use the cmux CLI to manage workspaces, panes, surfaces, notifications, and browser automation from scripts on macOS.",
      intro:
        "The cmux CLI controls workspaces, panes, surfaces, notifications, and browser automation from scripts on macOS.",
      capabilitiesDesc:
        "Commands create and inspect cmux workspaces, panes, surfaces, and browser sessions.",
      idFormat:
        "Every cmux object has stable identifiers for scripts and agent integrations.",
    };

    const metadata = await auditedDocsMetadata({
      locale: "en",
      pageKey: "api",
      path: "/docs/api",
      messages: (key) => pageMessages[key] ?? key,
    });

    expect(typeof metadata.title).toBe("string");
  });
});
