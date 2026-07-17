// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Manaflow, Inc.

import { describe, expect, it } from "bun:test";
import { SHARE_ID_LENGTH } from "../src/core";
import {
  MAX_REQUEST_BYTES,
  MAX_TITLE_LENGTH,
  parseCreateBody,
  parseSharePath,
  readBoundedJson,
} from "../src/validate";

const SHARE_ID = "A".repeat(SHARE_ID_LENGTH);

describe("parseSharePath", () => {
  it("parses host and viewer lanes", () => {
    expect(parseSharePath(`/v1/share/${SHARE_ID}/host`)).toEqual({
      shareId: SHARE_ID,
      lane: "host",
    });
    expect(parseSharePath(`/v1/share/${SHARE_ID}/ws`)).toEqual({
      shareId: SHARE_ID,
      lane: "ws",
    });
  });

  it("rejects malformed ids and lanes", () => {
    expect(parseSharePath(`/v1/share/${SHARE_ID}/other`)).toBeNull();
    expect(parseSharePath(`/v1/share/short/ws`)).toBeNull();
    expect(parseSharePath(`/v1/share/${"A".repeat(SHARE_ID_LENGTH + 1)}/ws`)).toBeNull();
    expect(parseSharePath(`/v1/share/${"!".repeat(SHARE_ID_LENGTH)}/ws`)).toBeNull();
    expect(parseSharePath(`/v1/share/${SHARE_ID}`)).toBeNull();
    expect(parseSharePath(`/v1/share//ws`)).toBeNull();
    expect(parseSharePath(`/v2/share/${SHARE_ID}/ws`)).toBeNull();
  });
});

describe("parseCreateBody", () => {
  it("accepts a missing title", () => {
    expect(parseCreateBody({})).toEqual({ ok: true, title: undefined });
  });

  it("trims the title and treats whitespace-only as absent", () => {
    expect(parseCreateBody({ title: "  demo  " })).toEqual({ ok: true, title: "demo" });
    expect(parseCreateBody({ title: "   " })).toEqual({ ok: true, title: undefined });
  });

  it("rejects non-string and oversized titles", () => {
    expect(parseCreateBody({ title: 42 })).toEqual({ ok: false, error: "invalid_title" });
    expect(parseCreateBody({ title: "a".repeat(MAX_TITLE_LENGTH + 1) })).toEqual({
      ok: false,
      error: "invalid_title",
    });
    expect(parseCreateBody({ title: "a".repeat(MAX_TITLE_LENGTH) })).toEqual({
      ok: true,
      title: "a".repeat(MAX_TITLE_LENGTH),
    });
  });
});

function postRequest(
  body: string | ReadableStream<Uint8Array> | null,
  headers: Record<string, string> = {},
): Request {
  return new Request("https://share.example/v1/share/create", {
    method: "POST",
    body,
    headers,
  });
}

/** A chunked body with no usable Content-Length, as an attacker would send. */
function chunkedRequest(chunks: readonly Uint8Array[]): Request {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk);
      controller.close();
    },
  });
  return postRequest(stream);
}

describe("readBoundedJson", () => {
  it("parses a small JSON object", async () => {
    const result = await readBoundedJson(postRequest(JSON.stringify({ title: "x" })));
    expect(result).toEqual({ ok: true, value: { title: "x" } });
  });

  it("treats an absent or empty body as an empty object", async () => {
    expect(await readBoundedJson(postRequest(null))).toEqual({ ok: true, value: {} });
    expect(await readBoundedJson(postRequest(""))).toEqual({ ok: true, value: {} });
  });

  it("rejects an oversized Content-Length up front with 413", async () => {
    const result = await readBoundedJson(
      postRequest("{}", { "content-length": String(MAX_REQUEST_BYTES + 1) }),
    );
    expect(result).toEqual({ ok: false, status: 413 });
  });

  it("aborts a chunked body the moment it crosses the cap", async () => {
    const chunk = new Uint8Array(1024).fill(0x61);
    const chunks = Array.from({ length: MAX_REQUEST_BYTES / 1024 + 1 }, () => chunk);
    const result = await readBoundedJson(chunkedRequest(chunks));
    expect(result).toEqual({ ok: false, status: 413 });
  });

  it("rejects invalid JSON and non-object payloads with 400", async () => {
    expect(await readBoundedJson(postRequest("not json"))).toEqual({ ok: false, status: 400 });
    expect(await readBoundedJson(postRequest("[1,2]"))).toEqual({ ok: false, status: 400 });
    expect(await readBoundedJson(postRequest("null"))).toEqual({ ok: false, status: 400 });
    expect(await readBoundedJson(postRequest('"str"'))).toEqual({ ok: false, status: 400 });
  });

  it("reassembles a multi-chunk body under the cap", async () => {
    const text = JSON.stringify({ title: "chunked" });
    const bytes = new TextEncoder().encode(text);
    const result = await readBoundedJson(
      chunkedRequest([bytes.slice(0, 5), bytes.slice(5)]),
    );
    expect(result).toEqual({ ok: true, value: { title: "chunked" } });
  });
});
