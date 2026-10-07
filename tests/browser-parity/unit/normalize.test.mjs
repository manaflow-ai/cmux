// The scenario normalizer: a session's file paths compare the same whatever
// temporary root the app or the dev driver used (TMPDIR, the app's own
// NSTemporaryDirectory, a root nested in another session's directory).
import { test } from "node:test";
import assert from "node:assert/strict";
import { normalize } from "../lib/normalize.mjs";

const origins = { primary: "http://localhost:4100", peer: "http://127.0.0.1:4101", insecure: null };
const golden = "[Image 1280x800 png: <TMP>/cmux-browser-repl/<SESSION>/image-1.png]";

test("normalize: an image path under the default temporary directory", () => {
  assert.equal(normalize("[Image 1280x800 png: /tmp/cmux-browser-repl/parity-18-print-p-5az4ja-1A2B3C4D-tmp/image-1.png]", origins), golden);
});

test("normalize: an image path under a temporary root other than this process's", () => {
  for (const root of ["/Users/cmux/brepl-merge/tmp", "/private/var/folders/zz/abc_123/T", "/var/folders/zz/abc_123/T"]) {
    assert.equal(normalize(`[Image 1280x800 png: ${root}/cmux-browser-repl/parity-18-print-p-5az4ja-1A2B3C4D-tmp/image-1.png]`, origins), golden, root);
  }
});

test("normalize: a temporary root inside another session's directory", () => {
  assert.equal(normalize("[Image 1280x800 png: /tmp/cmux-browser-repl/outer-9Z8Y7X6W-tmp/cmux-browser-repl/parity-18-print-p-5az4ja/image-1.png]", origins), golden);
});

test("normalize: a URL that names cmux-browser-repl is not a session path", () => {
  assert.equal(normalize("see http://localhost:4100/cmux-browser-repl/docs/x", origins), "see PRIMARY/cmux-browser-repl/docs/x");
});
