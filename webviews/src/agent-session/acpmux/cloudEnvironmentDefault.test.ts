import { describe, expect, test } from "bun:test";
import type { CloudEnvironment } from "../../pages/cloud/environmentModel";
import {
  AUTO_ENVIRONMENT,
  cloudEnvironmentRows,
  defaultPick,
  projectDefaultFrom,
  recentEnvironments,
  rememberEnvironment,
  type CloudEnvironmentControl,
  type RecentEnvironmentStore,
} from "./cloudEnvironmentChoice";

const env = (id: string, updated_at: string): CloudEnvironment => ({
  id,
  scope: "personal",
  name: id,
  is_default: false,
  setup_script: null,
  env_vars: [],
  secrets: [],
  network: { mode: "full", package_managers: false, domains: [] },
  created_at: updated_at,
  updated_at,
  updated_by: "user",
});
const memory = (): RecentEnvironmentStore => {
  const values = new Map<string, string>();
  return { getItem: (name) => values.get(name) ?? null, setItem: (name, value) => void values.set(name, value) };
};
const environments = [env("env_a", "2026-11-01"), env("env_b", "2026-11-03"), env("env_c", "2026-11-02")];

describe("the chip's per-project default", () => {
  test("the service's default comes first, and the local recents are not read", () => {
    const store = memory();
    rememberEnvironment("/src/app", "env_a", store);
    expect(recentEnvironments("/src/app", environments, store).map((item) => item.id)[0]).toBe("env_a");
    expect(recentEnvironments("/src/app", environments, store, "env_c").map((item) => item.id)).toEqual([
      "env_c",
      "env_b",
      "env_a",
    ]);
    // None set on the service: the newest, never the local list.
    expect(recentEnvironments("/src/app", environments, store, AUTO_ENVIRONMENT).map((item) => item.id)).toEqual([
      "env_b",
      "env_c",
      "env_a",
    ]);
  });

  test("a new chat starts on the default once, never over a pick made there", () => {
    expect(defaultPick(AUTO_ENVIRONMENT, "env_a", false)).toBe("env_a");
    expect(defaultPick(AUTO_ENVIRONMENT, "env_a", true)).toBeUndefined();
    expect(defaultPick("env_b", "env_a", false)).toBeUndefined();
    expect(defaultPick(AUTO_ENVIRONMENT, AUTO_ENVIRONMENT, false)).toBeUndefined();
    expect(defaultPick(AUTO_ENVIRONMENT, undefined, false)).toBeUndefined();
  });

  test("the reply reads as an id, none set, or no route", () => {
    expect(
      projectDefaultFrom([{ scope: "personal", repo: "o/n", environment: "env_a" }, { environment: "env_b" }]),
    ).toBe("env_a");
    expect(projectDefaultFrom([])).toBe(AUTO_ENVIRONMENT);
    expect(projectDefaultFrom({ environment: "env_a" })).toBeUndefined();
    expect(projectDefaultFrom(null)).toBeUndefined();
  });

  test("Make default is offered only when the pick is not already the default", () => {
    const control = (current: string, projectDefault?: string): CloudEnvironmentControl => ({
      recent: [{ id: "env_a", name: "a" }],
      current,
      onPick: () => undefined,
      onNew: () => undefined,
      onEdit: () => undefined,
      onNewMachine: () => undefined,
      ...(projectDefault !== undefined ? { projectDefault, onMakeDefault: () => undefined } : {}),
    });
    const kinds = (value: CloudEnvironmentControl) => cloudEnvironmentRows(value, "Auto").map((row) => row.kind);
    expect(kinds(control("env_a"))).not.toContain("makeDefault");
    expect(kinds(control("env_a", "env_a"))).not.toContain("makeDefault");
    expect(cloudEnvironmentRows(control("env_a", AUTO_ENVIRONMENT), "Auto")).toContainEqual({
      kind: "makeDefault",
      id: "env_a",
    });
    expect(kinds(control(AUTO_ENVIRONMENT, "env_a"))).toContain("makeDefault");
  });
});
