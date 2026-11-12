import { appendFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

export const workerName = "cmux-fleet-artifacts";

export async function preflight({ accountId, token, publicKey, request = fetch }) {
  if (!/^[a-f0-9]{32}$/.test(accountId ?? "") || !token) throw Error("Missing configured Cloudflare repository secrets");
  if (!/^[a-f0-9]{64}$/.test(publicKey ?? "")) throw Error("Artifact public key must be 64 lowercase hexadecimal characters");
  async function api(path) {
    // Read-only preflight. Never provision a bucket, relax public access, or
    // modify the existing lifecycle as part of an edge deployment.
    const response = await request(`https://api.cloudflare.com/client/v4/accounts/${accountId}/${path}`, {
      method: "GET",
      headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(30_000),
      redirect: "error",
    });
    if (!response.ok) throw Error(`Cloudflare preflight denied: HTTP ${response.status}`);
    const data = await response.json();
    if (data.success !== true) throw Error("Cloudflare preflight failed");
    return data.result;
  }
  const bucket = await api(`r2/buckets/${workerName}`);
  if (bucket?.name !== workerName) throw Error("Expected existing fleet artifact bucket");
  const managed = await api(`r2/buckets/${workerName}/domains/managed`);
  if (managed?.enabled !== false) throw Error("Fleet artifact bucket must have public r2.dev access disabled");
  const custom = await api(`r2/buckets/${workerName}/domains/custom`);
  if (!Array.isArray(custom?.domains) || custom.domains.length !== 0) throw Error("Fleet artifact bucket must have no public custom domains");
  const subdomain = (await api("workers/subdomain"))?.subdomain;
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(subdomain ?? "")) throw Error("Cloudflare account has no usable workers.dev subdomain");
  return `https://${workerName}.${subdomain}.workers.dev`;
}

export async function verifyUnsigned(origin, request = fetch) {
  const url = new URL(origin);
  if (url.protocol !== "https:" || !/^cmux-fleet-artifacts\.[a-z0-9-]+\.workers\.dev$/.test(url.hostname)
      || url.port || url.pathname !== "/" || url.search || url.hash || url.username || url.password) {
    throw Error("Invalid fleet artifact Worker origin");
  }
  const response = await request(`${url.origin}/artifacts/${"0".repeat(64)}`, {
    signal: AbortSignal.timeout(15_000), redirect: "error",
  });
  if (response.status !== 403 || response.headers.get("Cache-Control") !== "private, no-store"
      || await response.text() !== "Artifact unavailable") {
    throw Error("Unsigned artifact request was not rejected by the deployed Worker");
  }
}

async function main() {
  if (process.argv[2] === "preflight") {
    const origin = await preflight({
      accountId: process.env.CLOUDFLARE_ACCOUNT_ID,
      token: process.env.CLOUDFLARE_API_TOKEN,
      publicKey: process.env.ARTIFACT_PUBLIC_KEY,
    });
    if (!process.env.GITHUB_OUTPUT) throw Error("Missing GitHub output file");
    await appendFile(process.env.GITHUB_OUTPUT, `origin=${origin}\n`);
    console.log("Confirmed existing private fleet artifact bucket and Worker account.");
    return;
  }
  if (process.argv[2] === "verify") {
    await verifyUnsigned(process.env.ARTIFACT_CDN_ORIGIN);
    console.log("Unsigned artifact requests are rejected by the deployed edge.");
    return;
  }
  throw Error("Expected preflight or verify");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => {
    // Network errors can contain request details. Keep credentials and signed
    // URLs out of output, including unexpected exception stacks.
    console.error("Fleet artifact deployment check failed; check account permissions, public key and private bucket settings.");
    process.exitCode = 1;
  });
}
