import { afterEach, expect, test } from "bun:test";
import {
  docsCanonicalOrigin,
  docsChannel,
  nightlyDocsOrigin,
  releaseDocsOrigin,
} from "../app/lib/docs-channel";

const saved = {
  channel: process.env.CMUX_DOCS_CHANNEL,
  release: process.env.CMUX_RELEASE_DOCS_ORIGIN,
  nightly: process.env.CMUX_NIGHTLY_DOCS_ORIGIN,
};

afterEach(() => {
  process.env.CMUX_DOCS_CHANNEL = saved.channel;
  process.env.CMUX_RELEASE_DOCS_ORIGIN = saved.release;
  process.env.CMUX_NIGHTLY_DOCS_ORIGIN = saved.nightly;
});

test("release docs are the canonical default", () => {
  delete process.env.CMUX_DOCS_CHANNEL;
  delete process.env.CMUX_RELEASE_DOCS_ORIGIN;
  expect(docsChannel()).toBe("release");
  expect(releaseDocsOrigin()).toBe("https://cmux.com");
  expect(docsCanonicalOrigin()).toBe("https://cmux.com");
});

test("nightly docs canonically point to the release channel", () => {
  process.env.CMUX_DOCS_CHANNEL = "nightly";
  process.env.CMUX_RELEASE_DOCS_ORIGIN = "https://docs.cmux.com";
  process.env.CMUX_NIGHTLY_DOCS_ORIGIN = "https://nightly-docs.cmux.com";
  expect(docsChannel()).toBe("nightly");
  expect(nightlyDocsOrigin()).toBe("https://nightly-docs.cmux.com");
  expect(docsCanonicalOrigin()).toBe("https://docs.cmux.com");
});
