import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";

const wrapper = `
import { RequestAdmission } from "./index.js";
export { RequestAdmission };
export default {
  fetch(request, env) {
    return env.REQUEST_ADMISSION.getByName("production").fetch(request);
  },
};
`;

async function fixture(t) {
  const bundled = new URL("../.test-dist/index.js", import.meta.url);
  const mf = new Miniflare(convertV4MiniflareOptions({
    modules: [
      { type: "ESModule", path: new URL("../.test-dist/admission-wrapper.js", import.meta.url).pathname, contents: wrapper },
      { type: "ESModule", path: bundled.pathname, contents: readFileSync(bundled, "utf8") },
    ],
    compatibilityDate: "2026-09-20",
    compatibilityFlags: ["nodejs_compat"],
    durableObjects: { REQUEST_ADMISSION: { className: "RequestAdmission", useSQLite: true } },
  }));
  t.after(() => mf.dispose());
  return mf;
}

function admit(mf, runId) {
  return mf.dispatchFetch("https://admission.example/admit", {
    headers: runId === undefined ? {} : { "X-Cmux-Run-Id": String(runId) },
  });
}

test("production admission gives one run a bounded burst and leaves capacity for another run", async (t) => {
  const mf = await fixture(t);
  for (let request = 0; request < 16; request++) {
    assert.equal((await admit(mf, "35580000000")).status, 204);
  }
  assert.equal((await admit(mf, "35580000000")).status, 429);
  assert.equal((await admit(mf, "35580000001")).status, 204);
  assert.equal((await admit(mf)).status, 400);
  assert.equal((await admit(mf, "0")).status, 400);
});

test("production admission also bounds aggregate request volume", async (t) => {
  const mf = await fixture(t);
  for (let request = 0; request < 120; request++) {
    assert.equal((await admit(mf, String(40000000000 + request))).status, 204);
  }
  assert.equal((await admit(mf, "50000000000")).status, 429);
});
