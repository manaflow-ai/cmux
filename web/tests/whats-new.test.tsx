import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync } from "fs";
import path from "path";
import { NextRequest } from "next/server";
import { renderToStaticMarkup } from "react-dom/server";
import {
  compareWhatsNewVersions,
  documentLanguage,
  localizedText,
  localizedWhatsNewPath,
  parseWhatsNewDocument,
  webTryItLink,
  WhatsNewStore,
} from "../app/lib/whats-new";
import { WhatsNewDocumentView, type WhatsNewLabels } from "../app/[locale]/(landing)/whats-new/whats-new-document";
import { contentSigningPublicKey, loadNightlyDocuments, nightlyNotesBase } from "../app/lib/whats-new-nightly";
import { whatsNewAtomFeed } from "../app/lib/whats-new-feed";
import middleware from "../proxy";
import { locales } from "../i18n/routing";

// The validator's good fixture: the same file scripts/whats-new/test_validate.py
// passes and the app's Swift tests decode.
const fixturePath = path.resolve(__dirname, "../../scripts/whats-new/fixtures/good/1.0.0-nightly.42.json");
const fixture = readFileSync(fixturePath, "utf-8");

const labels: WhatsNewLabels = {
  categories: { new: "New", improved: "Improved", fixed: "Fixed", security: "Security" },
  channels: { stable: "Stable", rc: "Release candidate", nightly: "Nightly" },
  audiences: { teams: "For teams", enterprise: "For enterprise" },
  platforms: { macos: "macOS", ios: "iOS", cli: "CLI", web: "Web" },
  openInCmux: "Open in cmux",
  learnMore: "Learn more",
};

function minimal(version: string, extra: Record<string, unknown> = {}) {
  return JSON.stringify({
    schemaVersion: 1,
    version,
    channel: version.includes("-nightly.") ? "nightly" : version.includes("-rc.") ? "rc" : "stable",
    date: "2026-10-07",
    headline: { en: `Headline ${version}` },
    entries: [],
    ...extra,
  });
}

describe("What's New documents", () => {
  test("versions order numerically, prereleases (by number) before their release", () => {
    const shuffled = ["0.10.0", "0.9.0", "1.0.0-nightly.12", "0.10.0-rc.2", "1.0.0", "0.10.0-nightly.3", "1.0.0-nightly.3"];
    expect([...shuffled].sort(compareWhatsNewVersions)).toEqual([
      "0.9.0", "0.10.0-rc.2", "0.10.0-nightly.3", "0.10.0", "1.0.0-nightly.3", "1.0.0-nightly.12", "1.0.0",
    ]);
  });

  test("site locales map to the documents' Apple language codes and fall back to English", () => {
    expect(documentLanguage("no")).toBe("nb");
    expect(documentLanguage("zh-CN")).toBe("zh-Hans");
    expect(documentLanguage("zh-TW")).toBe("zh-Hant");
    expect(documentLanguage("ja")).toBe("ja");
    const text = { en: "New", ja: "新機能", "zh-Hant": "新功能", nb: "Nytt" };
    expect(localizedText(text, "ja")).toBe("新機能");
    expect(localizedText(text, "zh-TW")).toBe("新功能");
    expect(localizedText(text, "no")).toBe("Nytt");
    expect(localizedText(text, "de")).toBe("New");
    for (const locale of locales) expect(localizedText(text, locale).length).toBeGreaterThan(0);
  });

  test("the store reads the validator fixture and skips unreadable files with a warning", () => {
    const warnings: string[] = [];
    const store = new WhatsNewStore(
      [
        { name: "1.0.0-nightly.42.json", text: fixture },
        { name: "0.66.0.json", text: minimal("0.66.0") },
        { name: "0.67.0.json", text: "{not json" },
        { name: "0.68.0.json", text: minimal("0.69.0") },
        { name: "0.70.0.json", text: minimal("0.70.0", { schemaVersion: 2 }) },
        { name: "README.md", text: "ignored" },
      ],
      (message) => warnings.push(message),
    );
    expect(store.documents.map((document) => document.version)).toEqual(["1.0.0-nightly.42", "0.66.0"]);
    expect(warnings.length).toBe(3);
    expect(warnings.join("\n")).toContain("0.68.0.json: version must be 0.68.0");
    expect(store.neighbors("0.66.0").newer?.version).toBe("1.0.0-nightly.42");
    expect(store.find("9.9.9")).toBeUndefined();
  });

  test("unsafe media paths and non-https docs links are refused", () => {
    const entry = {
      id: "a", category: "new", title: { en: "T" }, summary: { en: "S." }, platforms: ["macos"], audience: "all",
      media: { kind: "image", light: "media/../../secret.png", dark: "media/a-dark.png", alt: { en: "A" } },
    };
    expect(parseWhatsNewDocument(minimal("0.66.0", { entries: [entry] }), "0.66.0").problem).toBe("an entry is invalid");
    const http = { ...entry, media: undefined, docs: "http://example.com" };
    expect(parseWhatsNewDocument(minimal("0.66.0", { entries: [http] }), "0.66.0").problem).toBe("an entry is invalid");
  });

  test("only cmux:// deeplinks become a web link; registry actions show nothing", () => {
    const base = { id: "a", category: "new" as const, title: { en: "T" }, summary: { en: "S" }, platforms: ["macos"], audience: "all" as const };
    expect(webTryItLink({ ...base, tryIt: { deeplink: "cmux://settings" } })).toBe("cmux://settings");
    expect(webTryItLink({ ...base, tryIt: { action: "updates.whatsNew" } })).toBeUndefined();
  });

  test("the page renders the fixture: headline, categories in order, links", () => {
    const { document } = parseWhatsNewDocument(fixture, "1.0.0-nightly.42");
    if (!document) throw new Error("fixture did not parse");
    const html = renderToStaticMarkup(<WhatsNewDocumentView document={document} locale="en" labels={labels} />);
    expect(html).toContain("Faster sidebar and a new What&#x27;s New page");
    expect(html).toContain("Nightly");
    expect(html.indexOf(">New<")).toBeLessThan(html.indexOf(">Fixed<"));
    expect(html).toContain('href="https://cmux.com/docs/sidebar"');
    expect(html).not.toContain("updates.whatsNew");
  });

  test("every document in whats-new/ parses", () => {
    const directory = path.resolve(__dirname, "../../whats-new");
    const names = readdirSync(directory).filter((name) => name.endsWith(".json"));
    const warnings: string[] = [];
    const store = new WhatsNewStore(
      names.map((name) => ({ name, text: readFileSync(path.join(directory, name), "utf-8") })),
      (message) => warnings.push(message),
    );
    expect(warnings).toEqual([]);
    expect(store.documents.length).toBe(names.length);
  });
});

describe("What's New routes", () => {
  test("a version page goes through the locale tree; raw files and media stay static", () => {
    const page = middleware(new NextRequest("https://cmux.com/whats-new/0.66.0", { headers: { "accept-language": "en" } }));
    expect(page.headers.get("x-middleware-rewrite")).toBe("https://cmux.com/en/whats-new/0.66.0");
    const json = middleware(new NextRequest("https://cmux.com/whats-new/0.66.0.json"));
    expect(json.headers.get("x-middleware-rewrite")).toBeNull();
    const media = middleware(new NextRequest("https://cmux.com/whats-new/media/0.66.0/a-light.png"));
    expect(media.headers.get("x-middleware-rewrite")).toBeNull();
    expect(localizedWhatsNewPath("ja", "0.66.0")).toBe("/ja/whats-new/0.66.0");
    expect(localizedWhatsNewPath("en")).toBe("/whats-new");
  });
});

describe("What's New nightly digests and feed", () => {
  const { generateKeyPairSync, sign } = require("node:crypto") as typeof import("node:crypto");
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const rawPublicKey = publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64");
  const files = new Map<string, Uint8Array>();
  const put = (name: string, value: unknown, valid = true) => {
    const data = new TextEncoder().encode(JSON.stringify(value));
    files.set(nightlyNotesBase + name, data);
    const signature = sign(null, valid ? data : new TextEncoder().encode("other"), privateKey).toString("base64");
    files.set(`${nightlyNotesBase}${name}.sig`, new TextEncoder().encode(signature));
  };
  const nightly = JSON.parse(fixture);
  put("index.json", { version: 1, builds: [{ build: "43" }, { build: "42" }, { build: "41" }] });
  put("43.json", { shortVersion: "1.0.0-nightly.43", highlights: [], changes: [] });
  put("42.json", { shortVersion: "1.0.0-nightly.42", whatsNew: nightly });
  put("41.json", { shortVersion: "1.0.0-nightly.41", whatsNew: { ...nightly, version: "1.0.0-nightly.41" } }, false);
  const fetcher = async (url: string) => files.get(url);

  test("only signed digests with entries are shown", async () => {
    const documents = await loadNightlyDocuments(fetcher, rawPublicKey);
    expect(documents.map((document) => document.version)).toEqual(["1.0.0-nightly.42"]);
    expect(await loadNightlyDocuments(fetcher, contentSigningPublicKey)).toEqual([]);
  });

  test("the Atom feed escapes text and links releases to their pages", () => {
    const { document } = parseWhatsNewDocument(fixture, "1.0.0-nightly.42");
    if (!document) throw new Error("fixture did not parse");
    const stable = { ...document, version: "0.66.0", channel: "stable" as const, headline: { en: "Tabs & <panes>" } };
    const xml = whatsNewAtomFeed([stable, document], "https://cmux.com");
    expect(xml).toContain("<title>cmux 0.66.0: Tabs &amp; &lt;panes&gt;</title>");
    expect(xml).toContain('<link href="https://cmux.com/whats-new/0.66.0"/>');
    expect(xml).toContain("<title>cmux Nightly 1.0.0-nightly.42: Faster sidebar and a new What&#x27;s New page</title>".replace("&#x27;", "'"));
    expect(xml.match(/<entry>/g)?.length).toBe(2);
  });
});
