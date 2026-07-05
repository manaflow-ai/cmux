const encoder = new TextEncoder();

export function timingSafeEqualString(a: string, b: string): boolean {
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  const length = Math.max(left.length, right.length);
  let diff = left.length ^ right.length;
  for (let i = 0; i < length; i += 1) {
    diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  }
  return diff === 0;
}

export function bearerToken(headers: Headers): string | null {
  const value = headers.get("authorization");
  if (!value) return null;
  const match = /^Bearer\s+(.+)$/i.exec(value.trim());
  return match?.[1] ?? null;
}

export function verifyInternalRequest(request: Request, expectedToken: string): boolean {
  const token = bearerToken(request.headers);
  if (!token) return false;
  return timingSafeEqualString(token, expectedToken);
}
