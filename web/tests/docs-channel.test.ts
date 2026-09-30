import { afterEach, expect, test } from "bun:test";
import {
  docsCanonicalOrigin,
  docsChannel,
  docsChannelUrl,
  docsNavPath,
  docsPathAvailableInChannel,
} from "../app/lib/docs-channel";
import {
  flatNavItems,
  navItemsForLocale,
} from "../app/[locale]/components/docs-nav-items";

const saved = {
  channel: process.env.CMUX_DOCS_CHANNEL,
};

afterEach(() => {
  process.env.CMUX_DOCS_CHANNEL = saved.channel;
});

test("channel switching preserves localized path, query, and hash", () => {
  expect(
    docsChannelUrl("nightly", "/ja/docs/base", "?q=base", "#install"),
  ).toBe("/ja/docs/nightly/base?q=base#install");
  expect(docsChannelUrl("release", "/ja/docs/nightly/base")).toBe(
    "/ja/docs/getting-started",
  );
});

test("pager matching removes locale and nightly prefixes", () => {
  expect(docsNavPath("/ja/docs/nightly/concepts", "ja")).toBe(
    "/docs/concepts",
  );
  expect(docsNavPath("/docs/nightly/concepts", "en")).toBe(
    "/docs/concepts",
  );
});

test("Base appears only in nightly documentation navigation", () => {
  const releasePaths = flatNavItems(navItemsForLocale("en", "release")).map(
    (item) => item.href,
  );
  const nightlyPaths = flatNavItems(navItemsForLocale("en", "nightly")).map(
    (item) => item.href,
  );

  expect(releasePaths).not.toContain("/docs/base");
  expect(nightlyPaths).toContain("/docs/base");
  expect(docsPathAvailableInChannel("release", "/docs/base")).toBe(false);
  expect(docsPathAvailableInChannel("nightly", "/docs/nightly/base")).toBe(true);
});

test("release docs are the canonical default", () => {
  delete process.env.CMUX_DOCS_CHANNEL;
  expect(docsChannel()).toBe("release");
  expect(docsCanonicalOrigin()).toBe("https://cmux.com");
});

test("nightly docs canonically point to the release channel", () => {
  process.env.CMUX_DOCS_CHANNEL = "nightly";
  expect(docsChannel()).toBe("nightly");
  expect(docsCanonicalOrigin()).toBe("https://cmux.com");
});
