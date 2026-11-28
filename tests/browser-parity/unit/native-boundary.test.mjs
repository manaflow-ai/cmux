// The reference host's secret guards (tests/browser-parity/lib/reference-host.mjs,
// the oracle for the Rust browser host; main's native-boundary.mjs merged in):
// generated TOTP codes are redacted while a server accepts them, binary fetch
// bodies and files read back are redacted by their bytes, and a capture whose
// mask the page drops is refused.
//
//   node --test tests/browser-parity/unit/native-boundary.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { loadRuntime, runDevCells } from "../lib/dev-driver.mjs";
import { createReferenceHost, totp } from "../lib/reference-host.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";

const ns = loadRuntime();
const fakeDriver = { name: "fake", call: async () => null, on: () => () => {} };
const reference = (host = { print() {} }) => createReferenceHost(ns, { host, driver: fakeDriver });
const VALUE = "v4lue-xyz-7731";
const SEED = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
const NOW = 1_800_000_015_000;

test("a generated TOTP code is redacted while a server accepts it", () => {
  const ref = reference();
  ref.host.secrets("set", { name: "otp", value: SEED, domains: ["example.com"], totp: true });
  const now = Date.now();
  const code = totp(SEED, now);
  const previous = totp(SEED, now - 30_000);
  assert.equal(ref.maskText(`code ${code} sent`), "code <secret:otp> sent");
  assert.equal(ref.maskText(`old ${previous}`), "old <secret:otp>");
  // Inside a longer number it is another number.
  assert.equal(ref.maskText(`9${code}9`), `9${code}9`);
});

test("binary fetch bodies and files read back are redacted by their bytes", async () => {
  const blob = Buffer.concat([Buffer.from([0xff, 0x00]), Buffer.from(VALUE), Buffer.from([0x80])]);
  const ref = reference({
    print() {},
    fsOp: (op) => (op === "readFile" ? blob.toString("base64") : null),
    fetch: async () => ({ status: 200, statusText: "OK", url: "https://example.com/blob", headers: { "content-type": "application/octet-stream" }, base64: blob.toString("base64"), redirected: false }),
  });
  const host = ref.host;
  host.secrets("set", { name: "k", value: VALUE, domains: ["example.com"] });
  for (const bytes of [Buffer.from(host.fsOp("readFile", { path: "blob.bin" }), "base64"), Buffer.from((await host.fetch("https://example.com/blob")).base64, "base64")]) {
    assert.equal(bytes.includes(Buffer.from(VALUE)), false);
    assert.ok(bytes.includes(Buffer.from("<secret:k>")));
    assert.equal(bytes[0], 0xff);
    assert.equal(bytes.at(-1), 0x80);
  }
});

test("a capture whose secret mask the page drops is refused", async () => {
  const servers = await startFixtureServers();
  const { primary } = servers.origins;
  try {
    const [out] = await runDevCells([
      {
        code: `
secrets.set("k", ${JSON.stringify(VALUE)}, { domains: ["localhost"] });
await page.goto(${JSON.stringify(primary)} + "/agent-tools.html");
await page.evaluate((v) => {
  document.body.innerHTML = '<input id="f">';
  const f = document.getElementById("f");
  f.value = v;
  new MutationObserver(() => f.style.removeProperty("-webkit-text-security")).observe(f, { attributes: true });
}, ${JSON.stringify(VALUE)});
console.log(await page.screenshot().then(() => "taken", (e) => "refused " + e.code));`,
      },
    ]);
    assert.equal(out.error, null, out.output);
    assert.equal(out.output.trim(), "refused invalid");
  } finally {
    await servers.close();
  }
});
