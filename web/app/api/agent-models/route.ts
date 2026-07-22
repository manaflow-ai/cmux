import { createHash } from "node:crypto";

import { agentModelCatalog } from "../../../data/agent-models";

export const runtime = "nodejs";
export const revalidate = 300;

const CACHE_CONTROL = "public, s-maxage=300, stale-while-revalidate=86400";
const ALLOW_METHODS = "GET, OPTIONS";
const ALLOW_HEADERS = "If-None-Match, Content-Type";
const PAYLOAD = JSON.stringify(agentModelCatalog);
const ETAG = `"${createHash("sha256").update(PAYLOAD).digest("base64url")}"`;

export async function GET(request: Request): Promise<Response> {
  if (matchesETag(request.headers.get("if-none-match"))) {
    return new Response(null, {
      status: 304,
      headers: commonHeaders(),
    });
  }

  return new Response(PAYLOAD, {
    status: 200,
    headers: {
      ...commonHeaders(),
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

export function OPTIONS(): Response {
  return new Response(null, {
    status: 204,
    headers: commonHeaders(),
  });
}

function commonHeaders(): Record<string, string> {
  return {
    "Cache-Control": CACHE_CONTROL,
    ETag: ETAG,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": ALLOW_METHODS,
    "Access-Control-Allow-Headers": ALLOW_HEADERS,
  };
}

function matchesETag(header: string | null): boolean {
  if (!header) return false;
  return header.split(",").some((value) => {
    const candidate = value.trim();
    return candidate === ETAG || candidate === "*";
  });
}
