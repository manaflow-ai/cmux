import { NextResponse } from "next/server";
import { checkRateLimit } from "@vercel/firewall";

import {
  captureInstallEvent,
  validInstallEventBody,
} from "../../../services/analytics/install";


export async function POST(request: Request): Promise<Response> {
  const ruleId = process.env.CMUX_ANALYTICS_RATE_LIMIT_ID?.trim();
  if (process.env.VERCEL === "1" && ruleId) {
    try {
      const { error, rateLimited } = await checkRateLimit(ruleId, { request });
      if (rateLimited || (error && error !== "not-found")) {
        // Analytics must never affect installation or clipboard UX.
        return new Response(null, {
          status: 204,
          headers: { "cache-control": "no-store" },
        });
      }
    } catch {
      // A firewall outage is still a best-effort analytics drop, not a reason
      // for install scripts to retry the request.
      return new Response(null, {
        status: 204,
        headers: { "cache-control": "no-store" },
      });
    }
  }
  const length = Number(request.headers.get("content-length") ?? "0");
  if (!Number.isFinite(length) || length > 512) {
    return NextResponse.json({ error: "invalid_request" }, { status: 400 });
  }
  let raw: string;
  try {
    raw = await request.text();
  } catch {
    return NextResponse.json({ error: "invalid_request" }, { status: 400 });
  }
  if (raw.length > 512) {
    return NextResponse.json({ error: "invalid_request" }, { status: 400 });
  }
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return NextResponse.json({ error: "invalid_request" }, { status: 400 });
  }
  const event = validInstallEventBody(body);
  if (!event) {
    return NextResponse.json({ error: "invalid_request" }, { status: 400 });
  }
  captureInstallEvent(event);
  return new Response(null, {
    status: 204,
    headers: { "cache-control": "no-store" },
  });
}
