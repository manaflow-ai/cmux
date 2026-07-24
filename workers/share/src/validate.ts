// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Manaflow, Inc.
//
// Bounded HTTP body parsing for the share worker, copied from the presence
// worker's validate.ts pattern: read the stream incrementally and abort the
// moment it crosses the cap, so a chunked or lying-Content-Length body can
// never make the worker buffer more than the limit.

import { SHARE_ID_LENGTH } from "./core";

export const MAX_REQUEST_BYTES = 16 * 1024;
export const MAX_TITLE_LENGTH = 256;

const SHARE_ID_RE = new RegExp(`^[0-9A-Za-z]{${SHARE_ID_LENGTH}}$`);

/** `/v1/share/<id>/<lane>` -> { shareId, lane } or null. Pure for tests. */
export function parseSharePath(
  pathname: string,
): { shareId: string; lane: "host" | "ws" } | null {
  const match = /^\/v1\/share\/([^/]+)\/(host|ws)$/.exec(pathname);
  if (!match || !match[1] || !match[2]) return null;
  const shareId = match[1];
  if (!SHARE_ID_RE.test(shareId)) return null;
  return { shareId, lane: match[2] as "host" | "ws" };
}

export type CreateParse =
  | { ok: true; title: string | undefined }
  | { ok: false; error: string };

/** Parse the `POST /v1/share/create` body (already JSON-decoded): an optional
 * bounded `title`. Pure for tests. */
export function parseCreateBody(body: Record<string, unknown>): CreateParse {
  if (body.title === undefined) return { ok: true, title: undefined };
  if (typeof body.title !== "string") return { ok: false, error: "invalid_title" };
  const title = body.title.trim();
  if (title.length > MAX_TITLE_LENGTH) return { ok: false, error: "invalid_title" };
  return { ok: true, title: title || undefined };
}

/** Bounded JSON body reader. An empty body is allowed and yields `{}` so the
 * create endpoint accepts a bare POST. */
export async function readBoundedJson(
  request: Request,
  maxBytes: number = MAX_REQUEST_BYTES,
): Promise<{ ok: true; value: Record<string, unknown> } | { ok: false; status: number }> {
  const lengthHeader = request.headers.get("content-length");
  if (lengthHeader && Number(lengthHeader) > maxBytes) {
    return { ok: false, status: 413 };
  }
  if (!request.body) return { ok: true, value: {} };

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      received += value.byteLength;
      if (received > maxBytes) {
        await reader.cancel();
        return { ok: false, status: 413 };
      }
      chunks.push(value);
    }
  } catch {
    return { ok: false, status: 400 };
  }

  if (received === 0) return { ok: true, value: {} };

  const bytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return { ok: false, status: 400 };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { ok: false, status: 400 };
  }
  return { ok: true, value: parsed as Record<string, unknown> };
}
