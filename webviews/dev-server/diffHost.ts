// Pure pieces of the diff viewer dev host (plugins.ts), split out so test/dev-server.test.ts can
// cover them. Dev server only; nothing here ships.
import fs from "node:fs";
import path from "node:path";

export const RPC_BODY_LIMIT = 1024 * 1024;

type HeaderValue = string | string[] | undefined;
type RequestLike = { method?: string; headers: Record<string, HeaderValue> };
type BodyStream = {
  on(event: "data", listener: (chunk: Buffer) => void): unknown;
  on(event: "end", listener: () => void): unknown;
  on(event: "error", listener: (error: Error) => void): unknown;
};
type ManifestFile = { request_path?: unknown; file_path?: unknown; mime_type?: unknown; remote_url?: unknown };

/// Whether `host` (the Host header) names this loopback server. Refusing other names keeps a
/// DNS-rebound page from reading the capability token or driving the sidecar.
export function isLoopbackHost(host: HeaderValue, port: number): boolean {
  return host === `127.0.0.1:${port}` || host === `localhost:${port}`;
}

/// The HTTP status that refuses an RPC request, or 0 when it may reach the sidecar:
/// POST only, from this server's own origin (or no Origin, as curl sends), to a loopback Host.
export function rpcRequestStatus({ method, headers }: RequestLike, port: number): number {
  if (method !== "POST") return 405;
  if (!isLoopbackHost(headers.host, port)) return 403;
  const origin = headers.origin;
  if (origin !== undefined && origin !== `http://127.0.0.1:${port}` && origin !== `http://localhost:${port}`) {
    return 403;
  }
  return 0;
}

/// Reads a request body, rejecting one larger than `limit` bytes.
export function readBody(request: BodyStream, limit = RPC_BODY_LIMIT): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        chunks.length = 0;
        reject(new Error("request too large"));
      } else chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks)));
    request.on("error", reject);
  });
}

/// The file for `<token>/<request path>` (the part after /__cmux-diff/resource/), as the app's
/// cmux-diff-viewer:// handler resolves it: only a local file the token's manifest lists, and only
/// when its real path is inside `root`.
export function resolveResource(root: string, resourcePath: string): { file: string; contentType: string } | undefined {
  const slash = resourcePath.indexOf("/");
  if (slash < 0) return undefined;
  const token = resourcePath.slice(0, slash);
  if (!/^[A-Za-z0-9-]{16,80}$/.test(token)) return undefined;
  const requestPath = `/${resourcePath.slice(slash + 1)}`;
  let manifest: { token?: unknown; files?: unknown };
  try {
    manifest = JSON.parse(fs.readFileSync(path.join(root, `.manifest-${token}.json`), "utf8"));
  } catch {
    return undefined;
  }
  if (manifest?.token !== token || !Array.isArray(manifest.files)) return undefined;
  const entry = (manifest.files as ManifestFile[]).find((file) => file?.request_path === requestPath);
  if (!entry || entry.remote_url || typeof entry.file_path !== "string") return undefined;
  let file: string;
  let realRoot: string;
  try {
    file = fs.realpathSync(entry.file_path);
    realRoot = fs.realpathSync(root);
  } catch {
    return undefined;
  }
  if (!file.startsWith(`${realRoot}/`) || !fs.statSync(file).isFile()) return undefined;
  const contentType = entry.mime_type === "text/x-diff" ? "text/plain; charset=utf-8" : String(entry.mime_type);
  return { file, contentType };
}

/// The viewer config the dev page loads in place of the one the CLI embeds.
export function payloadFor(
  { token, protocolVersion }: { token: string; protocolVersion: number },
  repo: string,
  defaultBase: string,
  query: URLSearchParams,
) {
  const requested = query.get("source");
  const kind = requested === "unstaged" || requested === "staged" ? requested : "branch";
  const base = query.get("base") || defaultBase;
  const sessionSource = kind === "branch" ? { kind, repoRoot: repo, baseRef: base } : { kind, repoRoot: repo };
  return {
    payload: {
      title: kind === "branch" ? `Branch diff vs ${base}` : `${kind[0].toUpperCase()}${kind.slice(1)} diff`,
      transport: { kind: "fetch", endpoint: "/__cmux-diff/rpc", protocolVersion },
      capabilityToken: token,
      sessionSource,
      repoRoot: repo,
      branchBaseRef: kind === "branch" ? base : undefined,
      layout: query.get("layout") === "unified" ? "unified" : "split",
      layoutSource: query.has("layout") ? "explicit" : "default",
    },
  };
}

/// The dev server's dependency cache directory under node_modules, one per port. The name is
/// part of every optimized module URL; it changed from `.vite-dev-server-<port>` so pages that
/// cached the old immutable modules load fresh ones.
export function dependencyCacheName(port: number): string {
  return `.vite-dev-deps-${port}`;
}

/// Whether a request path is one of the optimized dependency modules in `cacheName`.
export function isDependencyCacheRequest(pathname: string, cacheName: string): boolean {
  return pathname.startsWith(`/node_modules/${cacheName}/`);
}
