import { describe, expect, test } from "bun:test";
import { EnvironmentStore } from "./environmentStore";
import {
  environmentDraft,
  environmentPatch,
  headerIssue,
  hostsValid,
  secretHosts,
  secretRoutesSupported,
  validateEnvironment,
  SETUP_SCRIPT_BYTES,
  type CloudEnvironment,
  type EnvironmentClient,
  type EnvironmentPatch,
} from "./environmentModel";

function environment(overrides: Partial<CloudEnvironment> = {}): CloudEnvironment {
  return {
    id: "env_personal",
    scope: "personal",
    name: "Default",
    is_default: true,
    setup_script: null,
    env_vars: [{ name: "NODE_ENV", value: "development" }],
    secrets: [{ name: "PACKAGE_TOKEN", updated_at: "2026-11-01T00:00:00Z" }],
    network: { mode: "limited", package_managers: true, domains: [] },
    created_at: "2026-11-01T00:00:00Z",
    updated_at: "2026-11-01T00:00:00Z",
    updated_by: "user_example",
    ...overrides,
  };
}
/** The environment a routes-keeping service answers after `patch`. */
function applied(base: CloudEnvironment, patch: EnvironmentPatch): CloudEnvironment {
  const { set_secrets: set = [], remove_secrets: remove = [], ...fields } = patch;
  return {
    ...base,
    ...fields,
    secrets: [
      ...base.secrets.filter(
        (secret) => !remove.includes(secret.name) && !set.some((entry) => entry.name === secret.name),
      ),
      ...set.map(({ name, hosts, header }) => ({
        name,
        updated_at: "2026-11-02T00:00:00Z",
        ...(hosts ? { hosts } : {}),
        ...(header ? { header } : {}),
      })),
    ],
  };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
function fake(overrides: Partial<EnvironmentClient> = {}) {
  const writes: { id: string; patch: EnvironmentPatch }[] = [];
  const client: EnvironmentClient = {
    list: async () => [environment()],
    get: async (id) => environment({ id }),
    update: async (id, patch) => {
      writes.push({ id, patch });
      return applied(environment({ id }), patch);
    },
    derive: async () => ({ setup: { script: "#!/bin/bash\nnpm ci\n" } }),
    ...overrides,
  };
  return { store: new EnvironmentStore(client), writes, client };
}

const settle = async () => {
  for (let i = 0; i < 8; i++) await Promise.resolve();
};

describe("cloud environment editing", () => {
  test("Default resolves the personal scope even when a team Default is first", async () => {
    const { store } = fake({ list: async () => [environment({ id: "env_team", scope: "team" }), environment()] });
    await store.open();
    expect(store.getSnapshot().original?.id).toBe("env_personal");
  });

  test("a missing Default is recoverable without inventing an environment", async () => {
    let attempts = 0;
    const { store } = fake({ list: async () => (++attempts === 1 ? [] : [environment()]) });
    await store.open();
    expect(store.getSnapshot()).toMatchObject({ error: "missing", loading: false });
    await store.retry();
    expect(store.getSnapshot().original?.id).toBe("env_personal");
  });

  test("Default name stays out of PATCH; unchanged fields stay out too", () => {
    const original = environment();
    const draft = environmentDraft(original);
    draft.name = "Renamed";
    draft.script = "echo ready";
    expect(environmentPatch(original, draft)).toEqual({ setup_script: "echo ready" });
    expect(original.setup_script).toBeNull();
  });

  test("domain lines are trimmed, deduplicated and empty lines omitted", () => {
    const original = environment();
    const draft = environmentDraft(original);
    draft.network.domains = [" registry.example.org ", "", "registry.example.org", "  ", "github.com"];
    expect(environmentPatch(original, draft)).toEqual({
      network: { mode: "limited", package_managers: true, domains: ["registry.example.org", "github.com"] },
    });
  });

  test("cancel writes nothing and reopening never restores a typed secret", async () => {
    const { store, writes } = fake();
    await store.open();
    expect(store.getSnapshot().draft?.secrets).toEqual([{ id: expect.any(String), name: "PACKAGE_TOKEN", value: "" }]);
    store.edit({ secrets: [{ name: "PACKAGE_TOKEN", value: "test-write-only-value" }], script: "echo unsaved" });
    store.close();
    expect(store.getSnapshot().draft).toBeUndefined();
    expect(writes).toEqual([]);
    await store.open();
    expect(store.getSnapshot().draft?.secrets).toEqual([{ id: expect.any(String), name: "PACKAGE_TOKEN", value: "" }]);
    expect(store.getSnapshot().draft?.script).toBeNull();
  });

  test("save sends only secret additions/removals and clears the draft", async () => {
    const { store, writes } = fake();
    await store.open();
    store.edit({ secrets: [{ name: "NEW_TOKEN", value: "test-write-only-value" }] });
    await store.save();
    expect(writes).toEqual([
      {
        id: "env_personal",
        patch: {
          set_secrets: [{ name: "NEW_TOKEN", value: "test-write-only-value" }],
          remove_secrets: ["PACKAGE_TOKEN"],
        },
      },
    ]);
    expect(store.getSnapshot()).toMatchObject({ open: false, saving: false });
    expect(store.getSnapshot().draft).toBeUndefined();
  });

  test("existing blank secret is kept; a new blank secret prevents save", async () => {
    const { store, writes } = fake();
    await store.open();
    store.edit({ script: "echo ready" });
    await store.save();
    expect(writes[0]?.patch).toEqual({ setup_script: "echo ready" });
    await store.open();
    store.edit({ secrets: [{ name: "NEW_TOKEN", value: "" }] });
    await store.save();
    expect(store.getSnapshot().error).toBe("secret");
    expect(writes).toHaveLength(1);
  });

  test("failed save retains edits for one successful retry", async () => {
    const writes: EnvironmentPatch[] = [];
    const { store } = fake({
      update: async (_id, patch) => {
        writes.push(patch);
        if (writes.length === 1) throw new Error("temporary platform failure");
        return environment();
      },
    });
    await store.open();
    store.edit({ script: "echo retry", secrets: [{ name: "PACKAGE_TOKEN", value: "test-secret" }] });
    await store.save();
    expect(store.getSnapshot()).toMatchObject({ open: true, saving: false, error: "save" });
    expect(store.getSnapshot().draft?.script).toBe("echo retry");
    await store.save();
    expect(writes).toHaveLength(2);
    expect(writes[1]).toEqual(writes[0]);
    expect(store.getSnapshot().draft).toBeUndefined();
  });

  test("duplicate save, edits and dismissal cannot race an in-flight write", async () => {
    const pending = deferred<CloudEnvironment>();
    let writes = 0;
    const { store } = fake({
      update: async () => {
        writes++;
        return pending.promise;
      },
    });
    await store.open();
    store.edit({ script: "echo first" });
    const first = store.save();
    await store.save();
    store.edit({ script: "echo second" });
    store.close();
    expect(writes).toBe(1);
    expect(store.getSnapshot()).toMatchObject({ open: true, saving: true });
    expect(store.getSnapshot().draft?.script).toBe("echo first");
    pending.resolve(environment());
    await first;
    expect(store.getSnapshot().open).toBe(false);
  });

  test("stale load cannot replace a newer environment or reopen a cancelled sheet", async () => {
    const old = deferred<CloudEnvironment>();
    const { store } = fake({ get: async (id) => (id === "env_old" ? old.promise : environment({ id })) });
    const opening = store.open({ environmentId: "env_old" });
    await store.open({ environmentId: "env_new", section: "script" });
    old.resolve(environment({ id: "env_old" }));
    await opening;
    expect(store.getSnapshot().original?.id).toBe("env_new");
    expect(store.getSnapshot().section).toBe("script");
    const waiting = deferred<CloudEnvironment[]>();
    const cancelled = fake({ list: () => waiting.promise }).store;
    const load = cancelled.open();
    cancelled.close();
    waiting.resolve([environment()]);
    await load;
    expect(cancelled.getSnapshot().open).toBe(false);
    expect(cancelled.getSnapshot().draft).toBeUndefined();
  });

  test("derived prefill remains automatic and a late derivation never replaces typing", async () => {
    const pending = deferred<{ setup: { script: string } }>();
    const calls: unknown[] = [];
    const { store, writes } = fake({
      derive: (options) => {
        calls.push(options);
        return pending.promise;
      },
    });
    await store.open({ repo: "example/project", ref: "main", section: "script" });
    store.edit({ script: "echo mine" });
    pending.resolve({ setup: { script: "echo derived" } });
    await settle();
    expect(calls).toEqual([{ repo: "example/project", ref: "main", environment: "env_personal" }]);
    expect(store.getSnapshot().derivedScript).toBe("echo derived");
    expect(store.getSnapshot().draft?.script).toBe("echo mine");
    store.edit({ script: null, variables: [{ name: "NODE_ENV", value: "test" }] });
    await store.save();
    expect(writes[0]?.patch).toEqual({ env_vars: [{ name: "NODE_ENV", value: "test" }] });
  });

  test("every row has an id of the editor's own; it is never diffed or sent", async () => {
    const { store, writes } = fake();
    await store.open();
    const draft = store.getSnapshot().draft!;
    const ids = [...draft.variables, ...draft.secrets].map((row) => row.id);
    expect(ids.every(Boolean)).toBe(true);
    expect(new Set(ids).size).toBe(ids.length);
    // Ids alone change nothing.
    expect(environmentPatch(store.getSnapshot().original!, draft)).toEqual({});
    // A restated list keeps each place's id; a new row gets its own.
    store.edit({
      variables: [
        { name: "NODE_ENV", value: "test" },
        { name: "DEBUG", value: "1" },
      ],
      secrets: [
        { name: "PACKAGE_TOKEN", value: "tok" },
        { name: "NEW_TOKEN", value: "new" },
      ],
    });
    const edited = store.getSnapshot().draft!;
    expect(edited.variables[0]?.id).toBe(draft.variables[0]!.id);
    expect(edited.secrets[0]?.id).toBe(draft.secrets[0]!.id);
    expect(edited.secrets[1]?.id).toBeString();
    expect(edited.secrets[1]?.id).not.toBe(edited.secrets[0]?.id);
    await store.save();
    expect(writes[0]?.patch).toEqual({
      env_vars: [
        { name: "NODE_ENV", value: "test" },
        { name: "DEBUG", value: "1" },
      ],
      set_secrets: [
        { name: "PACKAGE_TOKEN", value: "tok" },
        { name: "NEW_TOKEN", value: "new" },
      ],
    });
    expect(JSON.stringify(writes[0]?.patch)).not.toContain('"id"');
  });

  test("late derived response cannot leak into a different sheet", async () => {
    const pending = deferred<{ setup: { script: string } }>();
    const { store } = fake({ derive: () => pending.promise });
    await store.open({ repo: "example/old" });
    store.close();
    await store.open({ environmentId: "env_new" });
    pending.resolve({ setup: { script: "echo old repository" } });
    await settle();
    expect(store.getSnapshot().derivedScript).toBeUndefined();
  });

  test("script limit measures UTF-8 bytes for both typing and file contents", async () => {
    const { store, writes } = fake();
    await store.open();
    store.edit({ script: "é".repeat(SETUP_SCRIPT_BYTES / 2) });
    await store.save();
    expect(writes).toHaveLength(1);
    await store.open();
    store.edit({ script: "é".repeat(SETUP_SCRIPT_BYTES / 2 + 1) });
    await store.save();
    expect(store.getSnapshot().error).toBe("script");
    expect(writes).toHaveLength(1);
    store.edit({ script: "echo keep" });
    await store.importScript({ size: 1, text: async () => "é".repeat(SETUP_SCRIPT_BYTES / 2 + 1) });
    expect(store.getSnapshot().error).toBe("script");
    expect(store.getSnapshot().draft?.script).toBe("echo keep");
    let reads = 0;
    await store.importScript({
      size: SETUP_SCRIPT_BYTES + 1,
      text: async () => {
        reads++;
        return "";
      },
    });
    expect(reads).toBe(0);
  });

  test("a late file read preserves later typing and never affects a reopened sheet", async () => {
    const { store } = fake();
    await store.open();
    const pending = deferred<string>();
    const reading = store.importScript({ size: 20, text: () => pending.promise });
    store.edit({ script: "echo typed" });
    pending.resolve("echo file");
    await reading;
    expect(store.getSnapshot().draft?.script).toBe("echo typed");
    const old = deferred<string>();
    const oldRead = store.importScript({ size: 20, text: () => old.promise });
    store.close();
    await store.open();
    old.resolve("echo old file");
    await oldRead;
    expect(store.getSnapshot().draft?.script).toBeNull();
  });

  test("duplicate and malformed variable names are refused without a write", async () => {
    const { store, writes } = fake();
    await store.open();
    for (const variables of [
      [{ name: "1INVALID", value: "test" }],
      [
        { name: "NAME", value: "a" },
        { name: "NAME", value: "b" },
      ],
    ]) {
      store.edit({ variables });
      await store.save();
      expect(store.getSnapshot().error).toBe("names");
    }
    expect(writes).toHaveLength(0);
  });
});

test("the last chosen setup file wins even if an earlier file finishes first", async () => {
  const { store } = fake();
  await store.open();
  const first = deferred<string>();
  const second = deferred<string>();
  const firstRead = store.importScript({ size: 20, text: () => first.promise });
  const secondRead = store.importScript({ size: 20, text: () => second.promise });
  first.resolve("echo first file");
  await firstRead;
  second.resolve("echo second file");
  await secondRead;
  expect(store.getSnapshot().draft?.script).toBe("echo second file");
});

test("choosing an oversized file invalidates an earlier pending file read", async () => {
  const { store } = fake();
  await store.open();
  store.edit({ script: "echo keep" });
  const first = deferred<string>();
  const firstRead = store.importScript({ size: 20, text: () => first.promise });
  let oversizedReads = 0;
  await store.importScript({
    size: SETUP_SCRIPT_BYTES + 1,
    text: async () => {
      oversizedReads++;
      return "echo oversized";
    },
  });
  first.resolve("echo old selection");
  await firstRead;
  expect(oversizedReads).toBe(0);
  expect(store.getSnapshot().error).toBe("script");
  expect(store.getSnapshot().draft?.script).toBe("echo keep");
});

test("editing away and back to the same text still invalidates a pending file read", async () => {
  const { store } = fake();
  await store.open();
  store.edit({ script: "echo original" });
  const pending = deferred<string>();
  const reading = store.importScript({ size: 20, text: () => pending.promise });
  store.edit({ script: "echo changed" });
  store.edit({ script: "echo original" });
  pending.resolve("echo selected file");
  await reading;
  expect(store.getSnapshot().draft?.script).toBe("echo original");
});

describe("secret delivery hosts and header", () => {
  const delivered = () =>
    environment({
      secrets: [
        { name: "PACKAGE_TOKEN", updated_at: "2026-11-01T00:00:00Z", hosts: ["registry.example.com"] },
        { name: "GITHUB_TOKEN", updated_at: "2026-11-01T00:00:00Z", hosts: ["api.github.com"] },
        {
          name: "SEARCH_KEY",
          updated_at: "2026-11-01T00:00:00Z",
          hosts: ["search.example.com"],
          header: { name: "x-api-key", format: "{value}" },
        },
      ],
    });

  /** `delivered` with PACKAGE_TOKEN as stored before every secret needed a host. */
  const legacy = () => {
    const base = delivered();
    return {
      ...base,
      secrets: base.secrets.map((secret) =>
        secret.name === "PACKAGE_TOKEN" ? { name: secret.name, updated_at: secret.updated_at } : secret,
      ),
    };
  };

  test("hosts parse from commas and spaces, lowercased and deduplicated, and validate exact names", () => {
    expect(secretHosts(" API.github.com, uploads.github.com  api.github.com,")).toEqual([
      "api.github.com",
      "uploads.github.com",
    ]);
    expect(hostsValid("")).toBe(true);
    expect(hostsValid("api.example.com")).toBe(true);
    for (const bad of [
      "https://api.example.com",
      "api.example.com:443",
      "api.example.com/v1",
      "*.example.com",
      "localhost",
    ])
      expect(hostsValid(bad)).toBe(false);
    expect(hostsValid(Array.from({ length: 8 }, (_, i) => `h${i}.example.com`).join(","))).toBe(true);
    expect(hostsValid(Array.from({ length: 9 }, (_, i) => `h${i}.example.com`).join(","))).toBe(false);
  });

  test("GET's hosts and header fill the draft; a value the server sends is never kept", async () => {
    const leaked = delivered();
    const { store } = fake({
      get: async () =>
        ({
          ...leaked,
          secrets: leaked.secrets.map((secret) => ({ ...secret, value: "server-leaked-value" })),
        }) as CloudEnvironment,
    });
    await store.open({ environmentId: "env_personal" });
    const secrets = store.getSnapshot().draft?.secrets;
    expect(secrets).toEqual([
      { id: expect.any(String), name: "PACKAGE_TOKEN", value: "", hosts: "registry.example.com" },
      { id: expect.any(String), name: "GITHUB_TOKEN", value: "", hosts: "api.github.com" },
      {
        id: expect.any(String),
        name: "SEARCH_KEY",
        value: "",
        hosts: "search.example.com",
        header: { name: "x-api-key", format: "{value}" },
      },
    ]);
    expect(JSON.stringify(store.getSnapshot())).not.toContain("server-leaked-value");
  });

  test("a set secret carries its hosts and a custom header; the default header is left to the platform", async () => {
    const { store, writes } = fake();
    await store.open();
    store.edit({
      secrets: [
        { name: "PACKAGE_TOKEN", value: "" },
        { name: "GITHUB_TOKEN", value: "ghp-test", hosts: "api.github.com, uploads.github.com" },
        {
          name: "SEARCH_KEY",
          value: "key-test",
          hosts: "search.example.com",
          header: { name: "X-Api-Key", format: "{value}" },
        },
        { name: "PLAIN", value: "plain-test", header: { name: "x", format: "nothing" } },
      ],
    });
    await store.save();
    expect(writes[0]?.patch).toEqual({
      set_secrets: [
        { name: "GITHUB_TOKEN", value: "ghp-test", hosts: ["api.github.com", "uploads.github.com"] },
        {
          name: "SEARCH_KEY",
          value: "key-test",
          hosts: ["search.example.com"],
          header: { name: "x-api-key", format: "{value}" },
        },
        { name: "PLAIN", value: "plain-test" },
      ],
    });
  });

  test("invalid hosts or a header without {value} block Save", async () => {
    const { store, writes } = fake();
    await store.open();
    store.edit({ secrets: [{ name: "PACKAGE_TOKEN", value: "v", hosts: "https://api.example.com" }] });
    await store.save();
    expect(store.getSnapshot().error).toBe("hosts");
    store.edit({
      secrets: [
        {
          name: "PACKAGE_TOKEN",
          value: "v",
          hosts: "api.example.com",
          header: { name: "authorization", format: "Bearer" },
        },
      ],
    });
    await store.save();
    expect(store.getSnapshot().error).toBe("header");
    store.edit({
      secrets: [
        {
          name: "PACKAGE_TOKEN",
          value: "v",
          hosts: "api.example.com",
          header: { name: "bad header", format: "{value}" },
        },
      ],
    });
    expect(validateEnvironment(store.getSnapshot().draft!)).toBe("header");
    expect(writes).toEqual([]);
  });

  test("changing an existing secret's delivery sends a metadata-only entry; an untouched one writes nothing", async () => {
    const { store, writes } = fake({ list: async () => [delivered()] });
    await store.open();
    const draft = store.getSnapshot().draft!;
    expect(environmentPatch(delivered(), draft)).toEqual({});
    store.edit({
      secrets: draft.secrets.map((row) =>
        row.name === "GITHUB_TOKEN" ? { ...row, hosts: "api.github.com, uploads.github.com" } : row,
      ),
    });
    await store.save();
    expect(writes[0]?.patch).toEqual({
      set_secrets: [{ name: "GITHUB_TOKEN", hosts: ["api.github.com", "uploads.github.com"] }],
    });
  });

  test("a custom header switched back to the default omits header; clearing every host is refused", () => {
    const original = delivered();
    const draft = environmentDraft(original);
    draft.secrets = draft.secrets.map((row) =>
      row.name === "SEARCH_KEY" ? { ...row, header: { name: "Authorization", format: "Bearer {value}" } } : row,
    );
    expect(environmentPatch(original, draft)).toEqual({
      set_secrets: [{ name: "SEARCH_KEY", hosts: ["search.example.com"] }],
    });
    draft.secrets = draft.secrets.map((row) => (row.name === "GITHUB_TOKEN" ? { ...row, hosts: "  " } : row));
    expect(validateEnvironment(draft, { routes: true })).toBe("hostless");
  });

  test("a new secret without a value is blocked, and the platform's value_required maps to the same error", async () => {
    const { store, writes } = fake();
    await store.open();
    store.edit({
      secrets: [
        { name: "PACKAGE_TOKEN", value: "" },
        { name: "NEW_TOKEN", value: "", hosts: "api.example.com" },
      ],
    });
    await store.save();
    expect(store.getSnapshot().error).toBe("secret");
    expect(writes).toEqual([]);

    // The stored secret was removed elsewhere after the sheet opened: its value-less entry is refused.
    const raced = fake({
      list: async () => [delivered()],
      update: async () => {
        throw Object.assign(new Error("refused"), { code: "cloud_environment.secret_value_required" });
      },
    });
    await raced.store.open();
    raced.store.edit({
      secrets: raced.store
        .getSnapshot()
        .draft!.secrets.map((row) => (row.name === "GITHUB_TOKEN" ? { ...row, hosts: "uploads.github.com" } : row)),
    });
    await raced.store.save();
    expect(raced.store.getSnapshot()).toMatchObject({ open: true, error: "secret" });
  });

  test("headers follow the platform's rules: lowercase token, no framing header, {value} in at most 256", () => {
    expect(headerIssue(undefined)).toBeUndefined();
    expect(headerIssue({ name: "X-Api-Key", format: "{value}" })).toBeUndefined();
    for (const name of ["host", "Content-Length", "transfer-encoding", "connection", "upgrade"])
      expect(headerIssue({ name, format: "{value}" })).toBe("route");
    expect(headerIssue({ name: "bad header", format: "{value}" })).toBe("header");
    expect(headerIssue({ name: "x".repeat(65), format: "{value}" })).toBe("header");
    expect(headerIssue({ name: "x-key", format: "Bearer" })).toBe("header");
    expect(headerIssue({ name: "x-key", format: `${"a".repeat(250)}{value}` })).toBe("header");
    expect(hostsValid("api.example.com:8443")).toBe(false);
  });

  test("a header with no hosts is never sent; a framing header blocks Save inline", async () => {
    const original = delivered();
    const draft = environmentDraft(original);
    draft.secrets = [{ name: "PACKAGE_TOKEN", value: "v", header: { name: "x-key", format: "{value}" } }];
    expect(environmentPatch(original, draft).set_secrets).toEqual([{ name: "PACKAGE_TOKEN", value: "v" }]);
    const { store, writes } = fake();
    await store.open();
    store.edit({
      secrets: [
        { name: "PACKAGE_TOKEN", value: "v", hosts: "api.example.com", header: { name: "host", format: "{value}" } },
      ],
    });
    await store.save();
    expect(store.getSnapshot().error).toBe("route");
    expect(writes).toEqual([]);
  });

  test("the platform's invalid_secret_route maps to the framing-header error; other refusals stay a save error", async () => {
    let code = "cloud_environment.invalid_secret_route";
    const { store } = fake({
      update: async () => {
        throw Object.assign(new Error("refused"), { code });
      },
    });
    await store.open();
    store.edit({ secrets: [{ name: "PACKAGE_TOKEN", value: "v", hosts: "api.example.com" }] });
    await store.save();
    expect(store.getSnapshot().error).toBe("route");
    code = "cloud_environment.something_else";
    await store.save();
    expect(store.getSnapshot().error).toBe("save");
  });

  test("a secret with hosts needs printable ASCII in its value and header format; a plain one does not", async () => {
    const { store, writes } = fake();
    await store.open();
    for (const value of ["line\nbreak", "caf\u00e9", "bell\u0007"]) {
      store.edit({ secrets: [{ name: "PACKAGE_TOKEN", value, hosts: "api.example.com" }] });
      await store.save();
      expect(store.getSnapshot().error).toBe("value");
    }
    expect(headerIssue({ name: "x-key", format: "Token\u0001 {value}" })).toBe("header");
    expect(headerIssue({ name: "x-key", format: "Token\t{value}" })).toBeUndefined();
    expect(writes).toEqual([]);
    store.edit({ secrets: [{ name: "PACKAGE_TOKEN", value: "tab\tand space ok", hosts: "api.example.com" }] });
    await store.save();
    expect(writes[0]?.patch.set_secrets).toEqual([
      { name: "PACKAGE_TOKEN", value: "tab\tand space ok", hosts: ["api.example.com"] },
    ]);
    const plain = fake();
    await plain.store.open();
    plain.store.edit({ secrets: [{ name: "PACKAGE_TOKEN", value: "multi\nline caf\u00e9" }] });
    await plain.store.save();
    expect(plain.writes[0]?.patch.set_secrets).toEqual([{ name: "PACKAGE_TOKEN", value: "multi\nline caf\u00e9" }]);
  });

  test("a secret stored without hosts needs its value with its first hosts; hosts-to-hosts does not", async () => {
    const { store, writes } = fake({ list: async () => [legacy()] });
    await store.open();
    const rows = store.getSnapshot().draft!.secrets;
    store.edit({
      secrets: rows.map((row) => (row.name === "PACKAGE_TOKEN" ? { ...row, hosts: "registry.example.com" } : row)),
    });
    await store.save();
    expect(store.getSnapshot().error).toBe("retype");
    expect(writes).toEqual([]);
    store.edit({
      secrets: rows.map((row) =>
        row.name === "PACKAGE_TOKEN"
          ? { ...row, value: "npm-token", hosts: "registry.example.com" }
          : row.name === "GITHUB_TOKEN"
            ? { ...row, hosts: "uploads.github.com" }
            : row,
      ),
    });
    await store.save();
    expect(writes[0]?.patch).toEqual({
      set_secrets: [
        { name: "PACKAGE_TOKEN", value: "npm-token", hosts: ["registry.example.com"] },
        { name: "GITHUB_TOKEN", hosts: ["uploads.github.com"] },
      ],
    });
  });

  test("where the service keeps routes, every secret needs a host: none blocks Save, one saves", async () => {
    const { store, writes } = fake({ list: async () => [environment({ secret_routes: true, secrets: [] })] });
    await store.open();
    store.edit({ secrets: [{ name: "DEPLOY_KEY", value: "key" }] });
    await store.save();
    expect(store.getSnapshot()).toMatchObject({ open: true, error: "hostless" });
    store.edit({ secrets: [{ name: "DEPLOY_KEY", value: "key", hosts: "   " }] });
    await store.save();
    expect(store.getSnapshot().error).toBe("hostless");
    expect(writes).toEqual([]);
    store.edit({ secrets: [{ name: "DEPLOY_KEY", value: "key", hosts: "deploy.example.com" }] });
    await store.save();
    expect(writes[0]?.patch.set_secrets).toEqual([{ name: "DEPLOY_KEY", value: "key", hosts: ["deploy.example.com"] }]);
    expect(store.getSnapshot()).toMatchObject({ open: false });
  });

  test("a secret stored without hosts loads as it is, never dropped, and blocks Save until it gets one", async () => {
    const { store, writes } = fake({ list: async () => [legacy()] });
    await store.open();
    const draft = store.getSnapshot().draft!;
    expect(draft.secrets.find((row) => row.name === "PACKAGE_TOKEN")).toEqual({
      id: expect.any(String),
      name: "PACKAGE_TOKEN",
      value: "",
    });
    expect(validateEnvironment(draft, { routes: true })).toBe("hostless");
    // An unrelated edit still can't save around it.
    store.edit({ name: "Renamed" });
    await store.save();
    expect(store.getSnapshot()).toMatchObject({ open: true, error: "hostless" });
    expect(writes).toEqual([]);
    // Without proof the service keeps routes there is no Sent to field, so the rule is not checked.
    expect(validateEnvironment(draft)).toBeUndefined();
  });

  test("the platform's invalid_value maps to the value error", async () => {
    const { store } = fake({
      update: async () => {
        throw Object.assign(new Error("refused"), { code: "cloud_environment.invalid_value" });
      },
    });
    await store.open();
    store.edit({ secrets: [{ name: "PACKAGE_TOKEN", value: "v", hosts: "api.example.com" }] });
    await store.save();
    expect(store.getSnapshot().error).toBe("value");
  });

  test("a value-only change still states the stored hosts and header in full", () => {
    const original = delivered();
    const draft = environmentDraft(original);
    draft.secrets = draft.secrets.map((row) => (row.name === "SEARCH_KEY" ? { ...row, value: "rotated" } : row));
    expect(environmentPatch(original, draft)).toEqual({
      set_secrets: [
        {
          name: "SEARCH_KEY",
          value: "rotated",
          hosts: ["search.example.com"],
          header: { name: "x-api-key", format: "{value}" },
        },
      ],
    });
  });
});

describe("only a service that keeps where secrets go gets delivery", () => {
  test("support needs proof: the declared flag or a stored secret with hosts, never an empty field", () => {
    expect(secretRoutesSupported(environment())).toBe(false);
    expect(secretRoutesSupported(environment({ secrets: [] }))).toBe(false);
    expect(secretRoutesSupported(environment({ secret_routes: true }))).toBe(true);
    expect(
      secretRoutesSupported(
        environment({
          secrets: [{ name: "GITHUB_TOKEN", updated_at: "2026-11-01T00:00:00Z", hosts: ["api.github.com"] }],
        }),
      ),
    ).toBe(true);
  });

  test("a reply that drops a sent route keeps the sheet open on what is stored, with the dropped error", async () => {
    const { store, writes } = fake({
      list: async () => [environment({ secret_routes: true })],
      // A service without cmux-platform#1008: hosts and header are dropped, the value saved as a plain variable.
      update: async (id, patch) => {
        writes.push({ id, patch });
        const reply = applied(environment({ id, secret_routes: true }), patch);
        return { ...reply, secrets: reply.secrets.map(({ name, updated_at }) => ({ name, updated_at })) };
      },
    });
    await store.open();
    store.edit({ secrets: [{ name: "PACKAGE_TOKEN", value: "npm-token", hosts: "registry.example.com" }] });
    await store.save();
    expect(writes).toHaveLength(1);
    expect(store.getSnapshot()).toMatchObject({ open: true, saving: false, error: "dropped" });
    expect(store.getSnapshot().draft?.secrets).toEqual([{ id: expect.any(String), name: "PACKAGE_TOKEN", value: "" }]);
    expect(JSON.stringify(store.getSnapshot())).not.toContain("npm-token");
  });

  test("a reply that keeps the route (in any host order, default header absent) closes the sheet", async () => {
    const { store, writes } = fake({
      list: async () => [environment({ secret_routes: true })],
      update: async (id, patch) => {
        writes.push({ id, patch });
        const reply = applied(environment({ id, secret_routes: true }), patch);
        return {
          ...reply,
          secrets: reply.secrets.map((secret) =>
            secret.hosts ? { ...secret, hosts: [...secret.hosts].reverse() } : secret,
          ),
        };
      },
    });
    await store.open();
    store.edit({
      secrets: [{ name: "PACKAGE_TOKEN", value: "npm-token", hosts: "registry.example.com, npm.example.com" }],
    });
    await store.save();
    expect(writes).toHaveLength(1);
    expect(store.getSnapshot()).toMatchObject({ open: false, saving: false });
  });
});
