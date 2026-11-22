// Per-session temporary directories compare as one placeholder: classic's
// `<TMP>/cmux-browser-repl/<session>/` and the Rust host's session files
// directory `<TMP>/cmux-browser-host/<pid>-<encoded working dir>/` (and its
// session roots `<TMP>/cmux-browser-host/roots/<session>/`) are the same
// thing, a session's private directory (parity 18 printed image paths).
//
//   node --test tests/browser-parity/unit/normalize.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import { normalize } from "../lib/normalize.mjs";

const tmp = os.tmpdir().replace(/\/$/, "");
const SESSION = "<TMP>/cmux-browser-repl/<SESSION>";

test("classic's session directory becomes the placeholder", () => {
  assert.equal(normalize(`[Image png: ${tmp}/cmux-browser-repl/abc-123/image-1.png]`, {}), `[Image png: ${SESSION}/image-1.png]`);
});

test("the Rust host's session files directory becomes the same placeholder", () => {
  assert.equal(
    normalize(`[Image 1280x800 png: ${tmp}/cmux-browser-host/10740-_tmp_parity-cmux-pvqN1g/image-1.png]`, {}),
    `[Image 1280x800 png: ${SESSION}/image-1.png]`,
  );
  assert.equal(normalize(`${tmp}/cmux-browser-host/roots/parity-18-a-x1/out.txt`, {}), `${SESSION}/out.txt`);
});

test("other host paths keep their names", () => {
  assert.equal(normalize(`${tmp}/cmux-browser-hostess/x`, {}), "<TMP>/cmux-browser-hostess/x");
});
