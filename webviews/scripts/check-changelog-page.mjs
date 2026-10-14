// Real page + bridge browser regression. Run on the webviews Freestyle snapshot.
import assert from "node:assert/strict";
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import { chromium } from "playwright";
import { createServer } from "vite-plus";

const news = {
  area: "browser",
  title: "Browser profiles can only be deleted by you.",
  prs: [101, 106],
};
const notes = [
  {
    build: "3850073942601",
    shortVersion: "1.0.0-nightly.3850073942601",
    date: "2026-10-14",
    publishedAt: "2026-10-14T12:20:00Z",
    highlights: [],
    changes: ["Inject the clock into the daily background so next-day art is deterministic (#102)"],
    items: [
      {
        title: "Inject the clock into the daily background so next-day art is deterministic",
        pr: 102,
      },
    ],
    summary: [{ group: "changed", title: "Opaque overlays draw the separator hairline" }],
    userNotes: [news, { area: "sidebar", title: "Sidebar headers keep a clear separator.", prs: [105] }],
  },
  {
    build: "3850000000001",
    shortVersion: "1.0.0-nightly.3850000000001",
    date: "2026-10-14",
    publishedAt: "2026-10-14T10:00:00Z",
    highlights: [],
    changes: [],
    userNotes: [{ ...news, title: "Only you can delete a browser profile." }],
  },
  {
    build: "3849484438101",
    shortVersion: "1.0.0-nightly.3849484438101",
    date: "2026-10-13",
    highlights: [],
    changes: ["Internal old change"],
    summary: [{ group: "changed", title: "Skills/cmux-browser: agents cannot delete browser profiles" }],
  },
];
const output = process.env.ARTIFACTS_DIR ?? resolve("artifacts/changelog");
await mkdir(output, { recursive: true });
const server = await createServer({
  configFile: resolve("vite.config.pages-dev.ts"),
  server: { port: 4199, host: "127.0.0.1" },
});
let browser;
try {
  await server.listen();
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({
    viewport: { width: 1100, height: 850 },
    locale: "en-US",
    timezoneId: "America/Los_Angeles",
    recordVideo: { dir: output, size: { width: 1100, height: 850 } },
  });
  await page.addInitScript((data) => {
    window.webkit = {
      messageHandlers: {
        cmuxPage: {
          postMessage: async (message) => {
            const value =
              message.op === "cmux.changelog.list"
                ? {
                    current: data[0].build,
                    builds: data.map(({ build, shortVersion, date, publishedAt }) => ({
                      build,
                      shortVersion,
                      date,
                      publishedAt,
                      highlights: 0,
                    })),
                  }
                : data.find((entry) => entry.build === message.params?.build);
            return { t: "ok", id: message.id, value };
          },
        },
      },
    };
  }, notes);
  await page.goto("http://127.0.0.1:4199/changelog/#/?from=1.0.0-nightly.3849484438101&to=1.0.0-nightly.3850073942601");
  const span = page.getByTestId("changelog.sinceLastUpdate");
  await span.locator(".cl-group").first().waitFor();
  await page.screenshot({ path: resolve(output, "whats-new.png"), fullPage: true });
  if (process.env.CMUX_CHANGELOG_CAPTURE_ONLY === "1") {
    console.log("Captured the unchanged page through the same bridge fixture");
  } else {
    assert.deepEqual(await span.locator(".cl-group h3").allTextContents(), ["Browser", "Sidebar"]);
    assert.equal(await span.locator(".cl-row-title").count(), 2, "Related PRs appear once across the update span");
    assert.equal(
      await span
        .locator(".cl-row-title")
        .first()
        .evaluate((el) => getComputedStyle(el).fontWeight),
      "400",
    );
    assert.equal(await span.locator(".cl-group svg").count(), 2, "Each area has a glyph");
    assert.match(await span.innerText(), /Oct 14 · 5:20 AM/);
    assert.doesNotMatch(
      await page.locator("body").innerText(),
      /nightly\.|Inject the clock|Opaque overlays|Skills\/cmux-browser/,
    );
    assert.match(await span.locator(".cl-build").last().getAttribute("title"), /1\.0\.0-nightly/);
    const first = span.locator(".cl-row-title").first();
    await first.hover();
    assert.equal(await first.getAttribute("href"), "https://github.com/manaflow-ai/cmux/pull/101");
    const box = await page.locator(".clj > main").boundingBox();
    assert.ok(box.width <= 720 && Math.abs(box.x + box.width / 2 - 550) < 2, JSON.stringify(box));
    await span.locator(".cl-changes summary").click();
    assert.match(await span.locator(".cl-changes").innerText(), /Inject the clock/);
    await page.setViewportSize({ width: 560, height: 850 });
    assert.ok(
      await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
      "Narrow pages do not overflow",
    );
    console.log("PASS: What's New real page bridge, filtering, dedup, labels, weight, links and layout");
  }
} finally {
  await browser?.close();
  await server.close();
}
