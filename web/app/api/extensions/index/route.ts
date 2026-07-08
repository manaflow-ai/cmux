import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import { NextResponse } from "next/server";

import { env } from "@/app/env";
import registryJson from "@/data/extensions-registry.json";
import {
  type ExtensionsRegistry,
  extensionsRegistrySchema,
  extensionsIndexResponseSchema,
  githubRepositorySchema,
  mapGithubRepositoriesToExtensions,
  type ExtensionsIndexResponse,
  type GitHubRepository,
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
export const awesomeCmuxRegistryUrl =
  "https://raw.githubusercontent.com/manaflow-ai/awesome-cmux/main/extensions.json";

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
    const registry = yield* loadExtensionsRegistry(span);

    yield* Effect.sync(() =>
      setSpanAttributes(span, { "cmux.extensions.registry_count": registry.extensions.length }),
    );

    const fetched = yield* Effect.forEach(
      registry.extensions,
      (entry) =>
        fetchGithubRepository(entry.repo, span).pipe(
          Effect.map((repository) => ({ repository, skipped: false as const })),
          Effect.catchAll((error) =>
            Effect.sync(() => {
              recordSpanError(span, error);
              return { repository: null, skipped: true as const };
            }),
          ),
        ),
      { concurrency: 8 },
    );

    const repositories = fetched
      .map((entry) => entry.repository)
      .filter((repository): repository is GitHubRepository => repository !== null);
    const skippedCount = fetched.filter((entry) => entry.skipped).length;

    yield* Effect.sync(() =>
      setSpanAttributes(span, { "cmux.extensions.skipped": skippedCount }),
    );

    if (registry.extensions.length > 0 && repositories.length === 0) {
      return yield* Effect.fail(
        new ExtensionsIndexUpstreamError({
          error: "github_extensions_unavailable",
        }),
      );
    }

    return yield* Effect.try({
      try: () =>
        extensionsIndexResponseSchema.parse({
          extensions: mapGithubRepositoriesToExtensions(repositories)
            .sort((left, right) => right.stars - left.stars || left.fullName.localeCompare(right.fullName)),
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

export function loadExtensionsRegistry(
  span?: Span,
): Effect.Effect<ExtensionsRegistry, ExtensionsIndexValidationError> {
  return fetchAwesomeCmuxRegistry(span).pipe(
    Effect.catchAll((error) =>
      Effect.gen(function* () {
        yield* Effect.sync(() => {
          if (span) recordSpanError(span, error);
        });
        return yield* parseBundledRegistry(span);
      }),
    ),
  );
}

function fetchAwesomeCmuxRegistry(
  span?: Span,
): Effect.Effect<ExtensionsRegistry, ExtensionsIndexError> {
  return Effect.gen(function* () {
    const response = yield* Effect.tryPromise({
      try: () =>
        fetch(awesomeCmuxRegistryUrl, {
          headers: rawGithubHeaders(),
          next: { revalidate },
          signal: AbortSignal.timeout(10_000),
        }),
      catch: (cause) =>
        new ExtensionsIndexUpstreamError({
          error: "extensions_registry_unavailable",
          cause,
        }),
    });

    yield* Effect.sync(() => {
      if (span) {
        setSpanAttributes(span, {
          "cmux.extensions.registry_upstream_status_code": response.status,
        });
      }
    });

    if (!response.ok) {
      return yield* Effect.fail(
        new ExtensionsIndexUpstreamError({
          error: "extensions_registry_unavailable",
          status: response.status,
        }),
      );
    }

    const raw = yield* Effect.tryPromise({
      try: () => response.json() as Promise<unknown>,
      catch: (cause) =>
        new ExtensionsIndexUpstreamError({
          error: "extensions_registry_invalid_json",
          cause,
        }),
    });

    const registry = yield* Effect.try({
      try: () => extensionsRegistrySchema.parse(raw),
      catch: (cause) =>
        new ExtensionsIndexValidationError({
          error: "extensions_registry_invalid",
          cause,
        }),
    });

    yield* Effect.sync(() => {
      if (span) setSpanAttributes(span, { "cmux.extensions.registry_source": "awesome-cmux" });
    });

    return registry;
  });
}

function parseBundledRegistry(
  span?: Span,
): Effect.Effect<ExtensionsRegistry, ExtensionsIndexValidationError> {
  return Effect.try({
    try: () => {
      const registry = extensionsRegistrySchema.parse(registryJson);
      if (span) {
        setSpanAttributes(span, { "cmux.extensions.registry_source": "bundled" });
      }
      return registry;
    },
    catch: (cause) =>
      new ExtensionsIndexValidationError({
        error: "extensions_registry_invalid",
        cause,
      }),
  });
}

function fetchGithubRepository(
  repo: string,
  span: Span,
): Effect.Effect<GitHubRepository, ExtensionsIndexError> {
  return Effect.gen(function* () {
    const response = yield* Effect.tryPromise({
      try: () => fetch(githubRepositoryUrl(repo), {
        headers: githubHeaders(),
        next: { revalidate },
        // Fail fast instead of tying up the route until the platform timeout;
        // the per-repo catchAll above records and skips the failed entry.
        signal: AbortSignal.timeout(10_000),
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

    return yield* Effect.try({
      try: () => githubRepositorySchema.parse(raw),
      catch: (cause) =>
        new ExtensionsIndexValidationError({
          error: "github_extensions_invalid_payload",
          cause,
        }),
    });
  });
}

function githubRepositoryUrl(repo: string): string {
  const [owner, name] = repo.split("/");
  return `https://api.github.com/repos/${encodeURIComponent(owner ?? "")}/${encodeURIComponent(name ?? "")}`;
}

function githubHeaders(): HeadersInit {
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    // GitHub rejects REST calls without a User-Agent (403).
    "User-Agent": "cmux-extensions-index (https://github.com/manaflow-ai/cmux)",
  };
  if (env.GITHUB_TOKEN) {
    headers.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
  }
  return headers;
}

function rawGithubHeaders(): HeadersInit {
  return {
    Accept: "application/json",
    "User-Agent": "cmux-extensions-index (https://github.com/manaflow-ai/cmux)",
  };
}
