import { describe, expect, test } from "bun:test";
import { EnvironmentCache, EnvironmentStore } from "./environmentStore";
import {
  conflictingFields,
  rebasedDraft,
  environmentConfig,
  environmentDraft,
  environmentPatch,
  filePathValid,
  repositoryValid,
  setupOutput,
  validateEnvironment,
  FILE_BYTES,
  type CloudEnvironment,
} from "./environmentModel";

function environment(overrides: Partial<CloudEnvironment> = {}): CloudEnvironment {
  return {
    id: "env_personal",
    scope: "personal",
    name: "Default",
    is_default: true,
    setup_script: null,
    env_vars: [],
    secrets: [],
    network: { mode: "limited", package_managers: true, domains: [] },
    created_at: "2026-11-01T00:00:00Z",
    updated_at: "2026-11-01T00:00:00Z",
    updated_by: "user_example",
    ...overrides,
  };
}
const configured = (overrides: Partial<CloudEnvironment> = {}) =>
  environment({ repo: null, ref: null, maintenance_script: null, files: [], image: "default", ...overrides });

describe("Codex-style environment fields", () => {
  test("an older service shows none of them and a save never sends them", () => {
    const older = environment();
    expect(environmentConfig(older)).toEqual({
      repository: false,
      maintenance: false,
      files: false,
      image: false,
      off: false,
    });
    const draft = { ...environmentDraft(older), repo: "octocat/hello-world", maintenance: "npm i", image: "x" };
    draft.files = [{ path: "a", content: "b" }];
    expect(environmentPatch(older, draft)).toEqual({});
  });

  test("a stored Off mode is offered even on a service that answers no other new field", () => {
    expect(environmentConfig(environment({ network: { mode: "off", package_managers: false, domains: [] } })).off).toBe(
      true,
    );
  });

  test("a service that answers them gets only what changed", () => {
    const original = configured({ available_images: ["default", "ubuntu-24.04"] });
    expect(environmentConfig(original)).toEqual({
      repository: true,
      maintenance: true,
      files: true,
      image: true,
      off: true,
    });
    const draft = environmentDraft(original);
    expect(environmentPatch(original, draft)).toEqual({});
    expect(
      environmentPatch(original, {
        ...draft,
        repo: " octocat/hello-world ",
        ref: "main",
        maintenance: "npm install\n",
        files: [{ id: "row-x", path: " .npmrc ", content: "registry=x\n" }],
        image: "ubuntu-24.04",
        network: { ...draft.network, mode: "off" },
      }),
    ).toEqual({
      repo: "octocat/hello-world",
      ref: "main",
      maintenance_script: "npm install\n",
      files: [{ path: ".npmrc", content: "registry=x\n" }],
      image: "ubuntu-24.04",
      network: { mode: "off", package_managers: true, domains: [] },
    });
  });

  test("clearing the repository clears its branch, and an emptied maintenance script is null", () => {
    const original = configured({ repo: "octocat/hello-world", ref: "dev", maintenance_script: "npm i" });
    const draft = { ...environmentDraft(original), repo: "", ref: "dev", maintenance: "" };
    expect(environmentPatch(original, draft)).toEqual({ repo: null, ref: null, maintenance_script: null });
  });

  test("validation stops a bad repository, a bad or repeated path and an oversized file", () => {
    const draft = environmentDraft(configured());
    expect(validateEnvironment({ ...draft, repo: "octocat" })).toBe("repository");
    expect(validateEnvironment({ ...draft, repo: "", ref: "main" })).toBe("repository");
    expect(validateEnvironment({ ...draft, repo: "octocat/x", ref: "bad ref" })).toBe("repository");
    expect(validateEnvironment({ ...draft, repo: "octocat/x", ref: "feature/one" })).toBeUndefined();
    expect(validateEnvironment({ ...draft, files: [{ path: "../x", content: "" }] })).toBe("filePath");
    expect(
      validateEnvironment({
        ...draft,
        files: [
          { path: "a", content: "" },
          { path: " a", content: "" },
        ],
      }),
    ).toBe("filePath");
    expect(validateEnvironment({ ...draft, files: [{ path: "a", content: "x".repeat(FILE_BYTES + 1) }] })).toBe(
      "fileSize",
    );
    expect(repositoryValid("", "")).toBe(true);
    expect(filePathValid("config/dev.json")).toBe(true);
    for (const path of ["", "~/.npmrc", "/etc/x", "a//b", "a/./b", "a/", ".git/config", ".GIT/x", "a\\b"])
      expect(filePathValid(path)).toBe(false);
    expect(
      validateEnvironment({
        ...draft,
        files: Array.from({ length: 21 }, (_, index) => ({ path: `f${index}`, content: "" })),
      }),
    ).toBe("filesSize");
    expect(
      validateEnvironment({
        ...draft,
        files: [0, 1, 2].map((index) => ({ path: `f${index}`, content: "x".repeat(FILE_BYTES) })),
      }),
    ).toBe("filesSize");
  });
});

describe("Setup output", () => {
  test("the environment's own run and snapshot state come first", () => {
    const own = configured({
      last_run: { kind: "maintenance", status: "succeeded", steps: [], log_tail: "ok" },
      snapshot_status: { state: "rebuilding", reason: "files" },
    });
    expect(setupOutput(own, { setup: null, status: "ready", steps: [], snapshot: { id: "snap" } })).toEqual({
      run: own.last_run!,
      snapshot: { state: "rebuilding", reason: "files" },
    });
  });

  test("without them, the derive reply's last script output and setup stand in", () => {
    expect(setupOutput(configured(), undefined)).toEqual({});
    const failed = setupOutput(configured(), {
      setup: null,
      status: "failed",
      steps: [{ id: "install", state: "failed" }],
      error: { code: "environment.install_failed", message: "Install failed.", log_tail: "npm error" },
      snapshot: null,
      script_output: { kind: "setup", attempt: 2, exit_code: 1, log_tail: "npm error", finished_at: 5 },
    });
    expect(failed.run).toMatchObject({ kind: "setup", status: "failed", log_tail: "npm error" });
    expect(failed.snapshot).toEqual({ state: "none" });
    const maintenance = setupOutput(configured(), {
      setup: { script: "" },
      status: "ready",
      steps: [],
      snapshot: { id: "snap" },
      script_output: { kind: "maintenance", attempt: 3, exit_code: 0, log_tail: "up to date", finished_at: 9 },
    });
    expect(maintenance.run).toMatchObject({ kind: "maintenance", status: "succeeded", log_tail: "up to date" });
    expect(maintenance.snapshot).toEqual({ state: "cached" });
    const rebuilding = setupOutput(configured(), {
      setup: null,
      status: "building",
      steps: [{ id: "install", state: "running" }],
      snapshot: { id: "snap" },
    });
    expect(rebuilding.run?.status).toBe("running");
    expect(rebuilding.snapshot).toEqual({ state: "rebuilding", reason: null });
  });
});

describe("cache first", () => {
  const client = (reply: () => Promise<CloudEnvironment>) => ({
    list: async () => [await reply()],
    get: reply,
    update: async () => reply(),
    derive: async () => ({ setup: { script: "" } }),
  });
  test("a reopened sheet draws what it read before, with no loading line, and refreshes in place", async () => {
    const cache = new EnvironmentCache();
    const first = configured({ id: "env_a", name: "Web", is_default: false });
    await new EnvironmentStore(
      client(async () => first),
      cache,
    ).open({ environmentId: "env_a" });
    let answer!: (value: CloudEnvironment) => void;
    const store = new EnvironmentStore(
      client(() => new Promise((resolve) => (answer = resolve))),
      cache,
    );
    const opening = store.open({ environmentId: "env_a" });
    expect(store.getSnapshot()).toMatchObject({ loading: false, draft: { name: "Web" } });
    answer({ ...first, name: "Web app", last_run: { kind: "setup", status: "running", steps: [] } });
    await opening;
    expect(store.getSnapshot().draft?.name).toBe("Web app");
    expect(store.getSnapshot().original?.last_run?.status).toBe("running");
  });

  test("an edit made before the refresh lands is kept, and only the run state updates", async () => {
    const cache = new EnvironmentCache();
    const first = configured({ id: "env_a", name: "Web", is_default: false });
    cache.put(first);
    let answer!: (value: CloudEnvironment) => void;
    const store = new EnvironmentStore(
      client(() => new Promise((resolve) => (answer = resolve))),
      cache,
    );
    const opening = store.open({ environmentId: "env_a" });
    store.edit({ maintenance: "npm i" });
    answer({ ...first, name: "Renamed elsewhere", snapshot_status: { state: "cached" } });
    await opening;
    expect(store.getSnapshot().draft).toMatchObject({ name: "Web", maintenance: "npm i" });
    expect(store.getSnapshot().original).toMatchObject({ name: "Web", snapshot_status: { state: "cached" } });
  });

  test("the cache keeps a bounded number of environments", () => {
    const cache = new EnvironmentCache(2);
    for (const id of ["env_a", "env_b", "env_c"]) cache.put(configured({ id }));
    expect(cache.get("env_a")).toBeUndefined();
    expect(cache.get("env_c")?.id).toBe("env_c");
  });
});

describe("a save that meets a change made elsewhere", () => {
  const conflict = Object.assign(new Error("conflict"), { code: "cloud_environment.revision_conflict" });
  type Call = { id: string; patch: import("./environmentModel").EnvironmentPatch };
  function service(stored: CloudEnvironment, elsewhere: (environment: CloudEnvironment) => CloudEnvironment) {
    let record = stored;
    let raced = false;
    const calls: Call[] = [];
    return {
      calls,
      client: {
        list: async () => [record],
        get: async () => record,
        derive: async () => ({ setup: { script: "" } }),
        update: async (id: string, patch: Call["patch"]) => {
          calls.push({ id, patch });
          if (!raced) {
            // Another window saves first.
            raced = true;
            record = { ...elsewhere(record), revision: (record.revision ?? 0) + 1 };
          }
          if (patch.expected_revision !== undefined && patch.expected_revision !== record.revision) throw conflict;
          const { expected_revision: _revision, ...fields } = patch;
          record = { ...record, ...fields, revision: (record.revision ?? 0) + 1 };
          return record;
        },
      },
    };
  }
  const base = configured({
    id: "env_a",
    is_default: false,
    revision: 4,
    env_vars: [{ name: "A", value: "1" }],
    files: [{ path: "a.txt", content: "a" }],
  });

  test("an older service sends no expected_revision", async () => {
    const { client, calls } = service({ ...base, revision: undefined }, (record) => record);
    const store = new EnvironmentStore(client);
    await store.open({ environmentId: "env_a" });
    store.edit({ name: "Renamed" });
    await store.save();
    expect(calls[0]!.patch).toEqual({ name: "Renamed" });
  });

  test("different fields: the edit moves onto the newest record and saves, keeping the other change", async () => {
    const { client, calls } = service(base, (record) => ({ ...record, files: [{ path: "b.txt", content: "b" }] }));
    const store = new EnvironmentStore(client);
    await store.open({ environmentId: "env_a" });
    store.edit({ variables: [{ name: "A", value: "2" }] });
    await store.save();
    expect(calls.map((call) => call.patch)).toEqual([
      { env_vars: [{ name: "A", value: "2" }], expected_revision: 4 },
      { env_vars: [{ name: "A", value: "2" }], expected_revision: 5 },
    ]);
    expect(store.getSnapshot().open).toBe(false);
  });

  test("the same field: the sheet says where, keeps every edit, and the person picks", async () => {
    const { client, calls } = service(base, (record) => ({ ...record, env_vars: [{ name: "A", value: "9" }] }));
    const store = new EnvironmentStore(client);
    await store.open({ environmentId: "env_a" });
    store.edit({ variables: [{ name: "A", value: "2" }], maintenance: "npm i" });
    await store.save();
    expect(calls).toHaveLength(1);
    const state = store.getSnapshot();
    expect(state).toMatchObject({ open: true, error: "conflict", conflict: { fields: ["env_vars"] } });
    expect(state.draft).toMatchObject({ variables: [{ name: "A", value: "2" }], maintenance: "npm i" });

    store.resolveConflict(false);
    expect(store.getSnapshot().draft).toMatchObject({ variables: [{ name: "A", value: "9" }], maintenance: "npm i" });
    expect(store.getSnapshot().original?.revision).toBe(5);
  });

  test("Keep my edits saves them on the newest revision", async () => {
    const { client, calls } = service(base, (record) => ({ ...record, env_vars: [{ name: "A", value: "9" }] }));
    const store = new EnvironmentStore(client);
    await store.open({ environmentId: "env_a" });
    store.edit({ variables: [{ name: "A", value: "2" }] });
    await store.save();
    store.resolveConflict(true);
    await store.save();
    expect(calls.at(-1)!.patch).toEqual({ env_vars: [{ name: "A", value: "2" }], expected_revision: 5 });
    expect(store.getSnapshot().open).toBe(false);
  });

  test("a typed secret value stays with its row across the move", () => {
    const original = configured({ secrets: [{ name: "T", updated_at: "1", hosts: ["api.example.com"] }] });
    const fresh = { ...original, files: [{ path: "x", content: "y" }] };
    const draft = environmentDraft(original);
    draft.secrets = [{ ...draft.secrets[0]!, value: "typed" }];
    const moved = rebasedDraft(original, fresh, draft, { mine: false });
    expect(moved.secrets[0]).toMatchObject({ name: "T", value: "typed" });
    expect(moved.files).toEqual([expect.objectContaining({ path: "x", content: "y" })]);
    expect(conflictingFields(original, fresh, environmentPatch(original, draft))).toEqual([]);
  });
});
