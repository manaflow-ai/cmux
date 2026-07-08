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
const { GET, awesomeCmuxRegistryUrl } = await import("../app/api/extensions/index/route");

type ExtensionResponseItem = {
  fullName: string;
  owner: string;
  ownerAvatarUrl?: string | null;
  description?: string | null;
  stars?: number | null;
  language?: string | null;
  pushedAt?: string | null;
  url: string;
  supported?: boolean;
};

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
    const remoteRegistry = {
      extensions: [
        { repo: "remote/alpha", addedAt: "2026-07-01" },
        { repo: "remote/beta", addedAt: "2026-07-02" },
      ],
    };
    const returnedRepos = remoteRegistry.extensions.map((entry, index) => ({
      repo: entry.repo,
      stars: remoteRegistry.extensions.length - index,
    }));
    const fetchMock = mock(async (...args: unknown[]) => {
      const input = args[0] as RequestInfo | URL;
      fetchCalls.push(input);
      const url = String(input);
      if (url === awesomeCmuxRegistryUrl) {
        return Response.json(remoteRegistry);
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
    expect(body.extensions.map((extension: { fullName: string }) => extension.fullName)).toEqual(
      [...returnedRepos]
        .sort((left, right) => right.stars - left.stars || left.repo.localeCompare(right.repo))
        .map((entry) => entry.repo),
    );
    expect(body.extensions.every((extension: { supported?: boolean }) => extension.supported === true)).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(remoteRegistry.extensions.length + 1);
    expect(fetchCalls.every((input) => !String(input).includes("/search/repositories"))).toBe(true);
  });

  test("keeps a minimal registry entry when its repository fetch fails", async () => {
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
      if (url === awesomeCmuxRegistryUrl) {
        return Response.json(registry);
      }
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
    const extensions = body.extensions as ExtensionResponseItem[];
    expect(extensions).toHaveLength(registry.extensions.length);
    expect(extensions.map((extension) => extension.fullName)).toEqual([
      ...returnedRepos
        .sort((left, right) => right.stars - left.stars || left.repo.localeCompare(right.repo))
        .map((entry) => entry.repo),
      failedRepo,
    ]);
    expect(extensions.every((extension) => extension.supported === true)).toBe(true);
    const fallback = extensions.find((extension) => extension.fullName === failedRepo);
    expect(fallback).toMatchObject({
      fullName: failedRepo,
      owner: failedRepo?.split("/")[0],
      description: null,
      stars: null,
      language: null,
      pushedAt: null,
      url: `https://github.com/${failedRepo}`,
    });
    expect(fallback && "ownerAvatarUrl" in fallback).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(registry.extensions.length + 1);
  });

  test("returns minimal metadata entries when every repository fetch fails", async () => {
    const fetchMock = mock(async (...args: unknown[]) => {
      const input = args[0] as RequestInfo | URL;
      const url = String(input);
      if (url === awesomeCmuxRegistryUrl) {
        return Response.json(registry);
      }
      return new Response(JSON.stringify({ message: "rate limited" }), {
        status: 403,
        headers: { "Content-Type": "application/json" },
      });
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await GET(new Request("https://cmux.test/api/extensions/index"));

    expect(response.status).toBe(200);
    const body = await response.json();
    const extensions = body.extensions as ExtensionResponseItem[];
    expect(extensions).toHaveLength(registry.extensions.length);
    expect(extensions.map((extension) => extension.fullName)).toEqual(
      registry.extensions.map((entry) => entry.repo),
    );
    for (const extension of extensions) {
      expect(extension).toMatchObject({
        owner: extension.fullName.split("/")[0],
        description: null,
        stars: null,
        language: null,
        pushedAt: null,
        url: `https://github.com/${extension.fullName}`,
        supported: true,
      });
      expect("ownerAvatarUrl" in extension).toBe(false);
    }
    expect(fetchMock).toHaveBeenCalledTimes(registry.extensions.length + 1);
  });

  test("returns a 200 JSON response for an empty registry", async () => {
    const fetchMock = mock(async (...args: unknown[]) => {
      const input = args[0] as RequestInfo | URL;
      const url = String(input);
      if (url === awesomeCmuxRegistryUrl) {
        return Response.json({ extensions: [] });
      }
      return new Response(JSON.stringify({ message: "unexpected url" }), { status: 500 });
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await GET(new Request("https://cmux.test/api/extensions/index"));

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.extensions).toEqual([]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("returns a 502 JSON error when the remote and bundled registries are invalid", async () => {
    const mutableSchema = extensionsRegistrySchema as typeof extensionsRegistrySchema & {
      parse: (input: unknown) => unknown;
    };
    const originalParse = mutableSchema.parse;
    mutableSchema.parse = () => {
      throw new Error("invalid bundled registry");
    };
    const fetchMock = mock(async () =>
      new Response(JSON.stringify({ message: "unavailable" }), {
        status: 503,
        headers: { "Content-Type": "application/json" },
      }),
    );
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    try {
      const response = await GET(new Request("https://cmux.test/api/extensions/index"));

      expect(response.status).toBe(502);
      expect(await response.json()).toEqual({ error: "extensions_registry_invalid" });
      expect(fetchMock).toHaveBeenCalledTimes(1);
    } finally {
      mutableSchema.parse = originalParse;
    }
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
