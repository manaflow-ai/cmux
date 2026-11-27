import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { NextRequest } from "next/server";
import { locales } from "../i18n/routing";
import {
  CONNECTED_PAGE_VARIANTS,
  DEFAULT_CONNECTED_PAGE_VARIANT,
  resolveConnectedPageVariant,
} from "../app/connected/variants";
import {
  CONNECTED_APP_IDS,
  connectedReturnHref,
  resolveConnectedApp,
  resolveConnectedStatus,
} from "../app/connected/apps";
import { GET } from "../app/connected/route";

async function page(query: string, language = "en"): Promise<string> {
  const response = await GET(
    new NextRequest(`https://cmux.com/connected${query}`, {
      headers: { "accept-language": language },
    }),
  );
  expect(response.status).toBe(200);
  expect(response.headers.get("content-type")).toContain("text/html");
  expect(response.headers.get("cache-control")).toBe("no-store");
  return response.text();
}

function primaryHref(html: string): string {
  const match = html.match(/<a class="primary" href="([^"]+)">/);
  expect(match).toBeTruthy();
  return match![1];
}

describe("connected page variants", () => {
  test("has at least three variants with unique ids and one default among them", () => {
    const ids = CONNECTED_PAGE_VARIANTS.map((variant) => variant.id);
    expect(ids.length).toBeGreaterThanOrEqual(3);
    expect(new Set(ids).size).toBe(ids.length);
    expect(ids).toContain(DEFAULT_CONNECTED_PAGE_VARIANT);
  });

  test("resolves known ids and falls back to the default", () => {
    for (const { id } of CONNECTED_PAGE_VARIANTS) {
      expect(resolveConnectedPageVariant(id)).toBe(id);
      expect(resolveConnectedPageVariant(` ${id.toUpperCase()} `)).toBe(id);
    }
    expect(resolveConnectedPageVariant(null)).toBe(DEFAULT_CONNECTED_PAGE_VARIANT);
    expect(resolveConnectedPageVariant("nope")).toBe(DEFAULT_CONNECTED_PAGE_VARIANT);
  });

  test("every variant renders the page", async () => {
    for (const { id } of CONNECTED_PAGE_VARIANTS) {
      const html = await page(`?app=linear&status=ok&variant=${id}`);
      expect(html).toContain(`data-variant="${id}"`);
      expect(html).toContain("You&#39;re signed in to Linear");
    }
  });
});

describe("connected page parameters", () => {
  test("names a known app and falls back to the generic page", async () => {
    expect(resolveConnectedApp("Slack")?.name).toBe("Slack");
    expect(resolveConnectedApp("evil<script>")).toBeNull();
    const generic = await page("?app=%3Cscript%3Ealert(1)%3C%2Fscript%3E&status=ok");
    expect(generic).toContain("You&#39;re signed in<");
    expect(generic).toContain('data-app="generic"');
    expect(generic).not.toContain("alert(1)");
  });

  test("status is ok unless it says error, and an error page does not open cmux by itself", async () => {
    expect(resolveConnectedStatus("ERROR")).toBe("error");
    expect(resolveConnectedStatus("whatever")).toBe("ok");
    const ok = await page("?app=sentry&status=ok");
    expect(ok).toContain("window.location.href=a.href");
    const failed = await page("?app=sentry&status=error");
    expect(failed).toContain("Couldn&#39;t sign in to Sentry");
    expect(failed).toContain('data-status="error"');
    expect(failed).not.toContain("<script>");
  });

  test("goes back only to cmux's own schemes", async () => {
    expect(connectedReturnHref(null)).toBe("cmux://");
    expect(connectedReturnHref("cmux-nightly")).toBe("cmux-nightly://");
    expect(connectedReturnHref("cmux-dev://")).toBe("cmux-dev://");
    for (const hostile of ["https://evil.example", "javascript:alert(1)", "evil", "cmux.evil", "//evil"]) {
      expect(connectedReturnHref(hostile)).toBe("cmux://");
    }
    expect(primaryHref(await page("?app=notion&return=javascript:alert(1)"))).toBe("cmux://");
    expect(primaryHref(await page("?app=notion&return=cmux-next"))).toBe("cmux-next://");
  });

  test("speaks the visitor's language and sets the direction", async () => {
    const japanese = await page("?app=github&status=ok", "ja,en;q=0.5");
    expect(japanese).toContain('lang="ja"');
    expect(japanese).toContain("GitHub にサインインしました");
    const arabic = await page("?app=github&status=ok", "ar");
    expect(arabic).toContain('dir="rtl"');
  });

  test("fetches no fonts or other outside resources", async () => {
    const html = await page("?app=figma&status=ok");
    expect(html).not.toMatch(/@import|fonts\.googleapis|<link /);
    expect(html).not.toMatch(/src="https?:/);
  });

  const registryPath = fileURLToPath(new URL("../../cmux-tui/crates/cmux-mcp-connect/src/registry.json", import.meta.url));
  // A web-only checkout has no cmux-tui; the full tree checks the lists agree.
  (existsSync(registryPath) ? test : test.skip)("the app list covers the MCP registry's OAuth servers", () => {
    const registry = JSON.parse(readFileSync(registryPath, "utf8")) as { servers: { name: string; auth: string }[] };
    const missing = registry.servers
      .filter((server) => server.auth === "oauth" && !server.name.includes("-"))
      .map((server) => server.name)
      .filter((name) => !CONNECTED_APP_IDS.includes(name));
    expect(missing).toEqual([]);
  });
});

describe("connected page messages", () => {
  test("every locale has every string, translated", () => {
    const english = JSON.parse(readFileSync(new URL("../messages/en.json", import.meta.url), "utf8")).connected;
    for (const locale of locales) {
      const messages = JSON.parse(readFileSync(new URL(`../messages/${locale}.json`, import.meta.url), "utf8")).connected;
      expect(Object.keys(messages).sort()).toEqual(Object.keys(english).sort());
      expect(messages.title).toContain("{app}");
      expect(messages.errorTitle).toContain("{app}");
      if (locale !== "en") expect(messages.button).not.toBe(english.button);
    }
  });
});
