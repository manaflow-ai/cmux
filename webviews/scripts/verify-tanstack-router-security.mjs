import { readFileSync } from "node:fs";

const expectedDependencyVersion = "1.170.11";
const expectedLockEntries = new Map([
  ["@tanstack/history", {
    version: "1.162.0",
    integrity: "sha512-79pf/RkhteYZTRgcR4F9kbk84P2N8rugQJswxfIqovlbRiT3yI7eBE+5QorIrZaOKktsgzRlXh1l/du/xpl4iA==",
  }],
  ["@tanstack/react-router", {
    version: "1.170.11",
    integrity: "sha512-gP2vzdyaI8Ow/Uz/MRPfK2wN09YwRI0Y/oF74Wuy9R3KmjbfJv2tLrkM+Onu1xWklSn3ugZarMPJXRE0kzrJTA==",
  }],
  ["@tanstack/react-store", {
    version: "0.9.3",
    integrity: "sha512-y2iHd/N9OkoQbFJLUX1T9vbc2O9tjH0pQRgTcx1/Nz4IlwLvkgpuglXUx+mXt0g5ZDFrEeDnONPqkbfxXJKwRg==",
  }],
  ["@tanstack/router-core", {
    version: "1.171.9",
    integrity: "sha512-QM5ZwLT9c5ZcTJW0QQZRRIBC4qjImUyUCXCVyuYVOF9xr76XLsJSX4F2dOxr9VptAv+W+TkWNOYdX8VaO9kdgA==",
  }],
  ["@tanstack/store", {
    version: "0.9.3",
    integrity: "sha512-8reSzl/qGWGGVKhBoxXPMWzATSbZLZFWhwBAFO9NAyp0TxzfBP0mIrGb8CP8KrQTmvzXlR/vFPPUrHTLBGyFyw==",
  }],
]);

const compromisedVersions = new Map([
  ["@tanstack/history", new Set(["1.161.9", "1.161.12"])],
  ["@tanstack/react-router", new Set(["1.169.5", "1.169.8"])],
  ["@tanstack/router-core", new Set(["1.169.5", "1.169.8"])],
]);

const packageJSON = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const lockfile = readFileSync(new URL("../bun.lock", import.meta.url), "utf8");

const dependencyVersion = packageJSON.dependencies?.["@tanstack/react-router"];
if (dependencyVersion !== expectedDependencyVersion) {
  fail(`@tanstack/react-router must be exact-pinned to ${expectedDependencyVersion}, found ${dependencyVersion ?? "missing"}`);
}

const lockEntries = parseTanstackLockEntries(lockfile);
for (const [name, expected] of expectedLockEntries) {
  const actual = lockEntries.get(name);
  if (!actual) {
    fail(`bun.lock is missing ${name}`);
  }
  if (actual.version !== expected.version) {
    fail(`${name} must resolve to ${expected.version}, found ${actual.version}`);
  }
  if (actual.integrity !== expected.integrity) {
    fail(`${name}@${expected.version} integrity changed`);
  }
}

for (const [name, actual] of lockEntries) {
  const badVersions = compromisedVersions.get(name);
  if (badVersions?.has(actual.version)) {
    fail(`${name}@${actual.version} is blocked by GHSA-g7cv-rxg3-hmpx`);
  }
}

console.log(`Verified @tanstack/react-router ${expectedDependencyVersion} and TanStack lockfile entries.`);

function parseTanstackLockEntries(text) {
  const entries = new Map();
  const linePattern = /^\s+"(@tanstack\/[^"]+)": \["@tanstack\/[^@"]+@([^"]+)",.*"(sha512-[^"]+)"\],?$/gm;
  for (const match of text.matchAll(linePattern)) {
    entries.set(match[1], {
      version: match[2],
      integrity: match[3],
    });
  }
  return entries;
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
