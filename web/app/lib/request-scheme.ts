import type { NextRequest } from "next/server";

export function requestIsExternallySecure(request: NextRequest): boolean {
  const forwardedProto = firstForwardedHeaderValue(request.headers.get("x-forwarded-proto"));
  if (forwardedProto) return forwardedProto.toLowerCase() === "https";
  return request.nextUrl.protocol === "https:";
}

function firstForwardedHeaderValue(value: string | null): string | null {
  return value?.split(",")[0]?.trim() || null;
}
