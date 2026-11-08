// Minimal AWS Signature Version 4 request signer (header auth, SHA-256).
//
// Written against node:crypto so the Bedrock leg needs no extra dependency.
// Path encoding follows the AWS SDK's default for non-S3 services: every
// segment is RFC 3986 encoded once more on top of what the URL carries.
import { createHash, createHmac } from "node:crypto";

export type AwsCredentials = {
  readonly accessKeyId: string;
  readonly secretAccessKey: string;
  readonly sessionToken?: string;
};

export type SignAwsRequestInput = {
  readonly method: string;
  readonly url: URL;
  readonly headers: Headers;
  readonly body: Uint8Array;
  readonly service: string;
  readonly region: string;
  readonly credentials: AwsCredentials;
  readonly now?: Date;
};

const ALGORITHM = "AWS4-HMAC-SHA256";

/** Returns a new Headers with host, x-amz-date, session token and authorization set. */
export function signAwsRequest(input: SignAwsRequestInput): Headers {
  const headers = new Headers(input.headers);
  const now = input.now ?? new Date();
  const amzDate = now.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
  const dateStamp = amzDate.slice(0, 8);
  headers.set("host", input.url.host);
  headers.set("x-amz-date", amzDate);
  headers.delete("authorization");
  if (input.credentials.sessionToken) {
    headers.set("x-amz-security-token", input.credentials.sessionToken);
  } else {
    headers.delete("x-amz-security-token");
  }
  const payloadHash = sha256Hex(input.body);
  headers.set("x-amz-content-sha256", payloadHash);

  const signedHeaderNames = [...headers.keys()].map((name) => name.toLowerCase()).sort();
  const canonicalHeaders = signedHeaderNames
    .map((name) => `${name}:${canonicalHeaderValue(headers.get(name) ?? "")}\n`)
    .join("");
  const signedHeaders = signedHeaderNames.join(";");
  const canonicalRequest = [
    input.method.toUpperCase(),
    canonicalPath(input.url.pathname),
    canonicalQuery(input.url.searchParams),
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join("\n");
  const scope = `${dateStamp}/${input.region}/${input.service}/aws4_request`;
  const stringToSign = [
    ALGORITHM,
    amzDate,
    scope,
    sha256Hex(Buffer.from(canonicalRequest, "utf8")),
  ].join("\n");
  const dateKey = hmac(Buffer.from(`AWS4${input.credentials.secretAccessKey}`, "utf8"), dateStamp);
  const signingKey = hmac(hmac(hmac(dateKey, input.region), input.service), "aws4_request");
  const signature = hmac(signingKey, stringToSign).toString("hex");
  headers.set(
    "authorization",
    `${ALGORITHM} Credential=${input.credentials.accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
  );
  return headers;
}

function canonicalPath(pathname: string): string {
  if (!pathname) return "/";
  return pathname.split("/").map(rfc3986Encode).join("/");
}

function canonicalQuery(params: URLSearchParams): string {
  const pairs: [string, string][] = [];
  for (const [key, value] of params) pairs.push([rfc3986Encode(key), rfc3986Encode(value)]);
  pairs.sort(([aKey, aValue], [bKey, bValue]) =>
    aKey < bKey ? -1 : aKey > bKey ? 1 : aValue < bValue ? -1 : aValue > bValue ? 1 : 0,
  );
  return pairs.map(([key, value]) => `${key}=${value}`).join("&");
}

function canonicalHeaderValue(value: string): string {
  return value.trim().replace(/\s+/g, " ");
}

function rfc3986Encode(value: string): string {
  return encodeURIComponent(value).replace(
    /[!'()*]/g,
    (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

function sha256Hex(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function hmac(key: Uint8Array, message: string): Buffer {
  return createHmac("sha256", key).update(message, "utf8").digest();
}
