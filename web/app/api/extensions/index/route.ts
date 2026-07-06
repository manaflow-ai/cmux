import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import { NextResponse } from "next/server";

import { env } from "@/app/env";
import blocklistJson from "@/data/extensions-blocklist.json";
import {
  extensionsBlocklistSchema,
  extensionsIndexResponseSchema,
  githubSearchResponseSchema,
  mapGithubRepositoriesToExtensions,
  type ExtensionsIndexResponse,
} from "./mapping";
import {
  recordSpanError,
  setSpanAttributes,
  withApiRouteSpan,
} from "../../../../services/telemetry";
import type { Span } from "@opentelemetry/api";

export const runtime = "nodejs";
export const revalidate = 1800;

const cacheControl = "public, s-maxage=1800, stale-while-revalidate=3600";

class ExtensionsIndexUpstreamError extends Data.TaggedError("ExtensionsIndexUpstreamError")<{
  readonly error: string;
  readonly cause?: unknown;
  readonly status?: number;
}> {}

class ExtensionsIndexValidationError extends Data.TaggedError("ExtensionsIndexValidationError")<{
  readonly error: string;
  readonly cause?: unknown;
}> {}

type ExtensionsIndexError = ExtensionsIndexUpstreamError | ExtensionsIndexValidationError;

export async function GET(request: Request): Promise<Response> {
  return withApiRouteSpan(
    request,
    "/api/extensions/index",
    { "cmux.subsystem": "extensions", "cmux.upstream.service": "github" },
    async (span): Promise<Response> => {
      return Effect.runPromise(
        loadExtensionsIndex(span).pipe(
          Effect.tap((body) =>
            Effect.sync(() =>
              setSpanAttributes(span, { "cmux.extensions.count": body.extensions.length }),
            ),
          ),
          Effect.map((body) =>
            NextResponse.json(body, {
              headers: { "Cache-Control": cacheControl },
            }),
          ),
          Effect.catchAll((error) =>
            Effect.sync(() => {
              recordSpanError(span, error);
              return NextResponse.json({ error: error.error }, { status: 502 });
            }),
          ),
        ),
      );
    },
  );
}

function loadExtensionsIndex(span: Span): Effect.Effect<ExtensionsIndexResponse, ExtensionsIndexError> {
  return Effect.gen(function* () {
    const response = yield* Effect.tryPromise({
      try: () => fetch(githubSearchUrl(), {
        headers: githubHeaders(),
        next: { revalidate },
      }),
      catch: (cause) =>
        new ExtensionsIndexUpstreamError({
          error: "github_extensions_unavailable",
          cause,
        }),
    });

    yield* Effect.sync(() =>
      setSpanAttributes(span, { "cmux.upstream.status_code": response.status }),
    );

    if (!response.ok) {
      return yield* Effect.fail(
        new ExtensionsIndexUpstreamError({
          error: "github_extensions_unavailable",
          status: response.status,
        }),
      );
    }

    const raw = yield* Effect.tryPromise({
      try: () => response.json() as Promise<unknown>,
      catch: (cause) =>
        new ExtensionsIndexUpstreamError({
          error: "github_extensions_invalid_json",
          cause,
        }),
    });

    const parsed = yield* Effect.try({
      try: () => githubSearchResponseSchema.parse(raw),
      catch: (cause) =>
        new ExtensionsIndexValidationError({
          error: "github_extensions_invalid_payload",
          cause,
        }),
    });

    const blocklist = yield* Effect.try({
      try: () => extensionsBlocklistSchema.parse(blocklistJson),
      catch: (cause) =>
        new ExtensionsIndexValidationError({
          error: "extensions_blocklist_invalid",
          cause,
        }),
    });

    return yield* Effect.try({
      try: () =>
        extensionsIndexResponseSchema.parse({
          extensions: mapGithubRepositoriesToExtensions(parsed.items, blocklist.blocked),
          fetchedAt: new Date().toISOString(),
        }),
      catch: (cause) =>
        new ExtensionsIndexValidationError({
          error: "extensions_index_invalid",
          cause,
        }),
    });
  });
}

function githubSearchUrl(): string {
  const url = new URL("https://api.github.com/search/repositories");
  url.searchParams.set("q", "topic:cmux-extension");
  url.searchParams.set("sort", "stars");
  url.searchParams.set("order", "desc");
  url.searchParams.set("per_page", "100");
  return url.toString();
}

function githubHeaders(): HeadersInit {
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
  };
  if (env.GITHUB_TOKEN) {
    headers.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
  }
  return headers;
}
