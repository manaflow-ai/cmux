import { afterAll, afterEach, describe, expect, mock, test } from "bun:test";

import extensionSchema from "../data/cmux-extension.schema.json";
import helloTuiManifest from "../../Examples/extensions/hello-tui/cmux-extension.json";
import registryJson from "../data/extensions-registry.json";
import {
  extensionsRegistrySchema,
  githubRepositorySchema,
  mapGithubRepositoriesToExtensions,
} from "../app/api/extensions/index/mapping";

const originalSkipEnvValidation = process.env.SKIP_ENV_VALIDATION;
process.env.SKIP_ENV_VALIDATION = "1";
const originalFetch = globalThis.fetch;
const registry = extensionsRegistrySchema.parse(registryJson);
const { GET } = await import("../app/api/extensions/index/route");

afterEach(() => {
  globalThis.fetch = originalFetch;
});

afterAll(() => {
  if (originalSkipEnvValidation === undefined) {
    delete process.env.SKIP_ENV_VALIDATION;
  } else {
    process.env.SKIP_ENV_VALIDATION = originalSkipEnvValidation;
  }
});

function repo(overrides: Record<string, unknown> = {}) {
  return githubRepositorySchema.parse({
    full_name: "owner/extension",
    owner: {
      login: "owner",
      avatar_url: "https://avatars.githubusercontent.com/u/1?v=4",
    },
    description: "Useful cmux extension",
    stargazers_count: 42,
    language: "TypeScript",
    pushed_at: "2026-07-01T12:00:00Z",
    created_at: "2026-06-01T12:00:00Z",
    html_url: "https://github.com/owner/extension",
    fork: false,
    archived: false,
    ...overrides,
  });
}

function registryRepo(repoName: string, stars: number) {
  const [owner] = repoName.split("/");
  return repo({
    full_name: repoName,
    owner: {
      login: owner,
      avatar_url: "https://avatars.githubusercontent.com/u/2?v=4",
    },
    html_url: `https://github.com/${repoName}`,
    stargazers_count: stars,
  });
}

function githubApiPath(repoName: string): string {
  const [owner, name] = repoName.split("/");
  return `/repos/${encodeURIComponent(owner ?? "")}/${encodeURIComponent(name ?? "")}`;
}

describe("extensions index mapping", () => {
  test("filters forks and archived repos and marks listed entries supported", () => {
    const extensions = mapGithubRepositoriesToExtensions(
      [
        repo(),
        repo({
          full_name: "owner/forked",
          html_url: "https://github.com/owner/forked",
          fork: true,
        }),
        repo({
          full_name: "owner/archived",
          html_url: "https://github.com/owner/archived",
          archived: true,
        }),
      ],
    );

    expect(extensions).toEqual([
      {
        fullName: "owner/extension",
        owner: "owner",
        ownerAvatarUrl: "https://avatars.githubusercontent.com/u/1?v=4",
        description: "Useful cmux extension",
        stars: 42,
        language: "TypeScript",
        pushedAt: "2026-07-01T12:00:00Z",
        createdAt: "2026-06-01T12:00:00Z",
        url: "https://github.com/owner/extension",
        supported: true,
      },
    ]);
  });

  test("preserves nullable GitHub metadata in the DTO", () => {
    const [extension] = mapGithubRepositoriesToExtensions(
      [
        repo({
          description: null,
          language: null,
        }),
      ],
    );

    expect(extension?.description).toBeNull();
    expect(extension?.language).toBeNull();
    expect(extension?.supported).toBe(true);
  });
});

describe("extensions index route", () => {
  test("returns registry repositories sorted by stars without topic search", async () => {
    const fetchCalls: Array<RequestInfo | URL> = [];
    const returnedRepos = registry.extensions.map((entry, index) => ({
      repo: entry.repo,
      stars: registry.extensions.length - index,
    }));
    const fetchMock = mock(async (...args: unknown[]) => {
      const input = args[0] as RequestInfo | URL;
      fetchCalls.push(input);
      const url = String(input);
      const match = returnedRepos.find((entry) => url.endsWith(githubApiPath(entry.repo)));
      if (match) {
        return Response.json(registryRepo(match.repo, match.stars));
      }
      return new Response(JSON.stringify({ message: "unexpected url" }), { status: 500 });
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await GET(new Request("https://cmux.test/api/extensions/index"));

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.extensions.map((extension: { fullName: string }) => extension.fullName)).toEqual(
      [...returnedRepos]
        .sort((left, right) => right.stars - left.stars || left.repo.localeCompare(right.repo))
        .map((entry) => entry.repo),
    );
    expect(body.extensions.every((extension: { supported?: boolean }) => extension.supported === true)).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(registry.extensions.length);
    expect(fetchCalls.every((input) => !String(input).includes("/search/repositories"))).toBe(true);
  });

  test("skips a registry entry when its repository fetch fails", async () => {
    const failedRepo = registry.extensions[0]?.repo;
    const returnedRepos = registry.extensions.slice(1).map((entry, index) => ({
      repo: entry.repo,
      stars: registry.extensions.length - index,
    }));
    expect(failedRepo).toBeDefined();
    expect(returnedRepos.length).toBeGreaterThan(0);

    const fetchMock = mock(async (...args: unknown[]) => {
      const input = args[0] as RequestInfo | URL;
      const url = String(input);
      if (failedRepo && url.endsWith(githubApiPath(failedRepo))) {
        return new Response(JSON.stringify({ message: "not found" }), {
          status: 404,
          headers: { "Content-Type": "application/json" },
        });
      }
      const match = returnedRepos.find((entry) => url.endsWith(githubApiPath(entry.repo)));
      if (match) {
        return Response.json(registryRepo(match.repo, match.stars));
      }
      return new Response(JSON.stringify({ message: "unexpected url" }), { status: 500 });
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await GET(new Request("https://cmux.test/api/extensions/index"));

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.extensions).toHaveLength(returnedRepos.length);
    expect(body.extensions.map((extension: { fullName: string }) => extension.fullName)).toEqual(
      [...returnedRepos]
        .sort((left, right) => right.stars - left.stars || left.repo.localeCompare(right.repo))
        .map((entry) => entry.repo),
    );
    expect(body.extensions.every((extension: { supported?: boolean }) => extension.supported === true)).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(registry.extensions.length);
  });

  test("returns a 502 JSON error when every registry repository fetch fails", async () => {
    const fetchMock = mock(async () =>
      new Response(JSON.stringify({ message: "unavailable" }), {
        status: 503,
        headers: { "Content-Type": "application/json" },
      }),
    );
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await GET(new Request("https://cmux.test/api/extensions/index"));

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "github_extensions_unavailable" });
    expect(fetchMock).toHaveBeenCalledTimes(registry.extensions.length);
  });
});

describe("cmux extension schema", () => {
  test("covers the hello-tui manifest required keys", () => {
    expect(extensionSchema.required).toEqual([
      "manifestVersion",
      "id",
      "name",
      "version",
      "panes",
    ]);

    for (const key of extensionSchema.required) {
      expect(helloTuiManifest).toHaveProperty(key);
    }

    expect(helloTuiManifest.manifestVersion).toBe(1);
    expect(Array.isArray(helloTuiManifest.panes)).toBe(true);
    expect(helloTuiManifest.panes.length).toBeGreaterThan(0);

    const paneRequired = extensionSchema.$defs.pane.required;
    expect(paneRequired).toEqual(["id", "title", "command"]);
    for (const pane of helloTuiManifest.panes) {
      for (const key of paneRequired) {
        expect(pane).toHaveProperty(key);
      }
      expect(Array.isArray(pane.command)).toBe(true);
      expect(pane.command.length).toBeGreaterThan(0);
    }
  });
});
