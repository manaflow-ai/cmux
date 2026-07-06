import { afterAll, afterEach, describe, expect, mock, test } from "bun:test";

import extensionSchema from "../data/cmux-extension.schema.json";
import helloTuiManifest from "../../Examples/extensions/hello-tui/cmux-extension.json";
import {
  githubSearchRepositorySchema,
  mapGithubRepositoriesToExtensions,
} from "../app/api/extensions/index/mapping";

const originalSkipEnvValidation = process.env.SKIP_ENV_VALIDATION;
process.env.SKIP_ENV_VALIDATION = "1";
const originalFetch = globalThis.fetch;
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
  return githubSearchRepositorySchema.parse({
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

describe("extensions index mapping", () => {
  test("filters forks, archived repos, and blocklisted full names", () => {
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
        repo({
          full_name: "Blocked/Repo",
          html_url: "https://github.com/Blocked/Repo",
        }),
      ],
      ["blocked/repo"],
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
      [],
    );

    expect(extension?.description).toBeNull();
    expect(extension?.language).toBeNull();
  });
});

describe("extensions index route", () => {
  test("returns a 502 JSON error when GitHub search fails", async () => {
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
    expect(fetchMock).toHaveBeenCalledTimes(1);
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
