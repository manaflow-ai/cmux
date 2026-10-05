// The dev backend's emulation of the native session's secret guards
// (tests/browser-parity/lib/native-boundary.mjs, dev-driver.mjs captures)
// matches the app's BrowserReplSecretStore, BrowserReplBoundary and
// BrowserReplCaptureMask: generated TOTP codes are redacted and masked while
// a server accepts them, binary fetch bodies and files read back are
// redacted by their bytes, and a capture whose mask the page drops is
// refused.
//
//   node --test tests/browser-parity/unit/native-boundary.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { loadRuntime, runDevCells } from "../lib/dev-driver.mjs";
import { createBoundary } from "../lib/native-boundary.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";

const T = loadRuntime().agentTools;
const VALUE = "v4lue-xyz-7731";
const SEED = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
const NOW = 1_800_000_015_000;

test("a generated TOTP code is redacted and capture-masked while a server accepts it", () => {
  const boundary = createBoundary(T, { now: () => NOW });
  boundary.secretsOp("set", { name: "otp", value: SEED, domains: ["example.com"], totp: true });
  const code = T.totp(SEED, NOW);
  const previous = T.totp(SEED, NOW - 30_000);
  assert.equal(boundary.redact(`code ${code} sent`), "code <secret:otp> sent");
  assert.equal(boundary.redact(`old ${previous}`), "old <secret:otp>");
  // Inside a longer number it is another number.
  assert.equal(boundary.redact(`9${code}9`), `9${code}9`);
  assert.deepEqual(boundary.redactValue({ n: Number(code) }), { n: "<secret:otp>" });
  const masks = boundary.prepare("tab.screenshot", {}).secretMasks || [];
  assert.ok(masks.some((m) => m.value === code && m.domains.some((d) => d.host === "example.com")), JSON.stringify(masks.map((m) => m.value)));
});

test("binary fetch bodies and files read back are redacted by their bytes", async () => {
  const blob = Buffer.concat([Buffer.from([0xff, 0x00]), Buffer.from(VALUE), Buffer.from([0x80])]);
  const boundary = createBoundary(T);
  const host = boundary.wrapHost({
    print() {},
    fsOp: (op) => (op === "readFile" ? blob.toString("base64") : null),
    fetch: async () => ({ status: 200, statusText: "OK", url: "https://example.com/blob", headers: { "content-type": "application/octet-stream" }, base64: blob.toString("base64"), redirected: false }),
  });
  boundary.secretsOp("set", { name: "k", value: VALUE, domains: ["example.com"] });
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
