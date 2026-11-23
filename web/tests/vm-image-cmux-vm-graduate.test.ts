import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { DEFAULT_LOCK_PATH } from "../scripts/cmux-vm-image/lock";
import { GRADUATED_PATH, GRADUATED_REPO_PATH, NONE, graduate, graduatedInstallCommand, parseGraduated, parseSummary, readGraduated } from "../scripts/cmux-vm-image/graduate";
import { isBaseInput, layerKeys } from "../scripts/cmux-vm-image/layers";
import { runChild } from "./helpers/run-child";

const lockText = readFileSync(DEFAULT_LOCK_PATH, "utf8");

describe("graduate", () => {
  const rows = [
    { name: "apt jq", people: 12 },
    { name: "npm typescript", people: 30 },
    { name: "npm @biomejs/biome", people: 10 },
    { name: "apt ripgrep", people: 9 },
    { name: "uv ruff", people: 40 },
    { name: "cargo bat", people: 40 },
    { name: "npm npm", people: 50 },
    { name: "apt evil;rm", people: 99 },
    { name: "npm left-pad@1.0.0", people: 99 },
  ];

  test("moves apt and npm names held by at least minPeople, most people first", () => {
    const { graduated, added } = graduate(rows, NONE, 10);
    expect(graduated).toEqual({ apt: ["jq"], npm: ["@biomejs/biome", "typescript"] });
    expect(added.map((r) => r.name)).toEqual(["npm typescript", "apt jq", "npm @biomejs/biome"]);
  });

  test("keeps what already graduated and adds nothing twice", () => {
    const { graduated, added } = graduate(rows, { apt: ["jq", "zstd"], npm: [] }, 10);
    expect(graduated.apt).toEqual(["jq", "zstd"]);
    expect(added.map((r) => r.name)).toEqual(["npm typescript", "npm @biomejs/biome"]);
    expect(graduate([], { apt: ["zstd"], npm: [] }, 10)).toEqual({ graduated: { apt: ["zstd"], npm: [] }, added: [] });
  });

  test("parses the platform's summary answer and refuses an unsafe graduated.json", () => {
    expect(parseSummary('{"names":[{"name":"apt jq","people":12},{"bad":1}]}')).toEqual([{ name: "apt jq", people: 12 }]);
    expect(() => parseSummary("{}")).toThrow();
    expect(parseGraduated(undefined)).toEqual(NONE);
    expect(() => parseGraduated('{"apt":["jq; curl x"]}')).toThrow();
    expect(() => parseGraduated('{"npm":"typescript"}')).toThrow();
  });

  test("the checked-in list parses", () => {
    expect(() => readGraduated(GRADUATED_PATH)).not.toThrow();
  });

  test("the install command is valid sh and installs by name only", async () => {
    const cmd = graduatedInstallCommand({ apt: ["jq", "zstd"], npm: ["@biomejs/biome"] }, "apt-get update -qq");
    expect(cmd).toContain("apt-get install -y -qq --no-install-recommends jq zstd");
    expect(cmd).toContain("npm i -g --no-audit --no-fund --no-update-notifier @biomejs/biome");
    const r = await runChild("sh", ["-n"], { input: cmd, timeout: 10_000 });
    expect(r.status).toBe(0);
    expect(graduatedInstallCommand(NONE, "x")).toBe('echo "graduated: 0 apt, 0 npm"');
  });
});

describe("graduated names and the layer keys", () => {
  test("no names keeps the agents key; names change it and leave the system key", () => {
    const none = layerKeys(lockText, [], "tree", NONE);
    const some = layerKeys(lockText, [], "tree", { apt: ["jq"], npm: [] });
    expect(some.system).toBe(none.system);
    expect(some.agents).not.toBe(none.agents);
    expect(layerKeys(lockText, [], "tree", { apt: ["jq"], npm: ["typescript"] }).agents).not.toBe(some.agents);
  });

  test("graduated.json is the agents layer's input, not the system layer's", () => {
    expect(isBaseInput(GRADUATED_REPO_PATH)).toBe(false);
    expect(isBaseInput("images/cmux-vm/bake.ts")).toBe(true);
  });
});
