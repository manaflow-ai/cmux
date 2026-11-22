const encoder = new TextEncoder();
const digestPattern = /^\/artifacts\/([a-f0-9]{64})$/;

function bytes(hex) {
  return Uint8Array.from(hex.match(/../g), (pair) => Number.parseInt(pair, 16));
}

function status(code, method = "GET") {
  return new Response(method === "HEAD" ? null : "Artifact unavailable", {
    status: code,
    headers: { "Cache-Control": "private, no-store" },
  });
}

async function authorize(url, publicKey) {
  if (url.protocol !== "https:" || url.username || url.password || url.hash
      || !digestPattern.test(url.pathname) || !/^[a-f0-9]{64}$/.test(publicKey ?? "")) {
    return false;
  }
  const query = [...url.searchParams.entries()];
  if (query.length !== 2 || url.searchParams.getAll("expires").length !== 1
      || url.searchParams.getAll("signature").length !== 1) {
    return false;
  }
  const expires = url.searchParams.get("expires");
  const signature = url.searchParams.get("signature");
  if (!/^[1-9][0-9]{0,11}$/.test(expires ?? "") || !/^[a-f0-9]{128}$/.test(signature ?? "")) {
    return false;
  }
  const now = Math.floor(Date.now() / 1000);
  if (Number(expires) <= now || Number(expires) > now + 900) return false;
  try {
    const key = await crypto.subtle.importKey("raw", bytes(publicKey), "Ed25519", false, ["verify"]);
    const message = encoder.encode(`fleet-artifact-v1\n${url.host}\n${url.pathname}\n${expires}`);
    return await crypto.subtle.verify("Ed25519", key, bytes(signature), message);
  } catch {
    return false;
  }
}

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      const response = status(405);
      response.headers.set("Allow", "GET, HEAD");
      return response;
    }
    let url;
    try {
      url = new URL(request.url);
    } catch {
      return status(403, request.method);
    }
    // Every request is authenticated before touching R2. No unsigned cache
    // path or public listing is exposed, and the Worker holds no signing key.
    if (!await authorize(url, env.ARTIFACT_PUBLIC_KEY)) return status(403, request.method);
    const key = `artifacts/${digestPattern.exec(url.pathname)[1]}`;
    try {
      const object = request.method === "HEAD" ? await env.ARTIFACTS.head(key) : await env.ARTIFACTS.get(key);
      if (!object) return status(404, request.method);
      const headers = new Headers({
        "Cache-Control": "private, no-store",
        "Content-Type": "application/zip",
        "Content-Length": String(object.size),
        "X-Content-Type-Options": "nosniff",
      });
      // Stream directly from the R2 binding through the edge. Do not clone or
      // tee a multi-hundred-megabyte artifact into an in-memory cache fill.
      return new Response(request.method === "HEAD" ? null : object.body, { headers });
    } catch {
      // Never log an exception containing a request URL or replayable signature.
      return status(503, request.method);
    }
  },
};
