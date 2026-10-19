/**
 * Live E2B smoke test. Run manually with E2B_API_KEY and E2B_TEMPLATE_ID in
 * the environment; it only deletes the exact sandbox id returned by create.
 */

const apiKey = process.env.E2B_API_KEY;
const templateId = process.env.E2B_TEMPLATE_ID;
if (apiKey === undefined || templateId === undefined) throw new Error("E2B_API_KEY and E2B_TEMPLATE_ID are required");

const api = process.env.E2B_API_URL ?? "https://api.e2b.app";
const sandboxDomain = process.env.E2B_SANDBOX_DOMAIN ?? "https://sandbox.e2b.app";
const headers = { "content-type": "application/json", "x-api-key": apiKey };

const requestJson = async (url: string, init: RequestInit = {}): Promise<Record<string, unknown>> => {
  const response = await fetch(url, { ...init, headers: { ...headers, ...(init.headers ?? {}) } });
  if (!response.ok) throw new Error(`${init.method ?? "GET"} ${url}: HTTP ${response.status}`);
  return (await response.json()) as Record<string, unknown>;
};

const frame = (value: unknown): Uint8Array => {
  const body = new TextEncoder().encode(JSON.stringify(value));
  const output = new Uint8Array(5 + body.length);
  output[0] = 0;
  new DataView(output.buffer).setUint32(1, body.length);
  output.set(body, 5);
  return output;
};

const envdOrigin = (domain: string, id: string): string => {
  const host = domain.replace(/^https?:\/\//u, "").replace(/\/$/u, "");
  if (host === "e2b.app" || host === "sandbox.e2b.app") return sandboxDomain;
  return `https://49983-${id}.${host}`;
};

let sandboxId: string | null = null;
try {
  const created = await requestJson(`${api}/v2/sandboxes`, {
    method: "POST",
    body: JSON.stringify({ templateID: templateId, timeout: 300, secure: true, metadata: { cmux_id: "smoke-e2b" } }),
  });
  sandboxId = String(created.sandboxID);
  const detail = await requestJson(`${api}/sandboxes/${encodeURIComponent(sandboxId)}`);
  const accessToken = String(detail.envdAccessToken);
  const domain = envdOrigin(String(detail.domain ?? "sandbox.e2b.app"), sandboxId);
  const envdHeaders = { "x-access-token": accessToken, "e2b-sandbox-id": sandboxId, "e2b-sandbox-port": "49983" };

  const exec = await fetch(`${domain}/process.Process/Start`, {
    method: "POST",
    headers: { ...envdHeaders, "content-type": "application/connect+json", "connect-protocol-version": "1", "connect-timeout-ms": "30000" },
    body: frame({ process: { cmd: "/bin/sh", args: ["-lc", "echo ok"] }, stdin: false }),
  });
  if (!exec.ok) throw new Error(`exec: HTTP ${exec.status}`);
  console.log("exec: ok");

  const filePath = "/tmp/cmux-e2b-smoke.txt";
  const content = new TextEncoder().encode("ok\n");
  const write = await fetch(`${domain}/files?path=${encodeURIComponent(filePath)}`, { method: "POST", headers: { ...envdHeaders, "content-type": "application/octet-stream", "content-length": String(content.length) }, body: content });
  if (!write.ok) throw new Error(`write: HTTP ${write.status}`);
  const read = await fetch(`${domain}/files?path=${encodeURIComponent(filePath)}`, { headers: envdHeaders });
  if (!read.ok || (await read.text()) !== "ok\n") throw new Error(`read: HTTP ${read.status}`);
  console.log("file: ok");

  const pause = await fetch(`${api}/sandboxes/${encodeURIComponent(sandboxId)}/pause`, { method: "POST", headers, body: JSON.stringify({ memory: true }) });
  if (!pause.ok) throw new Error(`pause: HTTP ${pause.status}`);
  await requestJson(`${api}/v2/sandboxes/${encodeURIComponent(sandboxId)}/connect`, { method: "POST", body: JSON.stringify({ timeout: 300 }) });
  console.log("pause/resume: ok");
} finally {
  if (sandboxId !== null) {
    const deleted = await fetch(`${api}/sandboxes/${encodeURIComponent(sandboxId)}`, { method: "DELETE", headers });
    if (!deleted.ok && deleted.status !== 404) throw new Error(`delete ${sandboxId}: HTTP ${deleted.status}`);
    console.log(`deleted exact sandbox ${sandboxId}`);
  }
}
