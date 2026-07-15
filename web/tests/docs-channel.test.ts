import { afterEach, expect, test } from "bun:test";
import {
  docsCanonicalOrigin,
  docsChannel,
  docsChannelUrl,
} from "../app/lib/docs-channel";

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
  expect(docsChannelUrl("release", "/ja/docs/nightly/base")).toBe("/ja/docs/base");
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
