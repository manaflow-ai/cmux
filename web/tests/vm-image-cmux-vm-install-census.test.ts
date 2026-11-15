import { describe, expect, test } from "bun:test";
import { NPM_NAME, PREFILL_NODE_DEPS, npmCachePrefillCommand, prefillNodeDeps } from "../scripts/cmux-vm-image/dep-cache";
import { measuredNpm, packageFromKey, rankInstalls, registryOf } from "../scripts/cmux-vm-image/install-census";

const readout = (counts: Record<string, number>) => ({ rollup: { counts: { "install-package": counts, install: { npm: 9 } } } });

describe("install census", () => {
  test("keys decode back to package names (tool_installs.rs package_key)", () => {
    expect(packageFromKey("npm:react")).toEqual({ manager: "npm", name: "react" });
    expect(packageFromKey("npm:types/node")).toEqual({ manager: "npm", name: "@types/node" });
    expect(packageFromKey("go:golang.org:x:tools:gopls")).toEqual({ manager: "go", name: "golang.org/x/tools/gopls" });
    expect(packageFromKey("pip:ruamel-yaml")).toEqual({ manager: "pip", name: "ruamel-yaml" });
    expect(packageFromKey("other")).toBeUndefined();
    expect(packageFromKey("npm:")).toBeUndefined();
  });

  test("ranks by machines first, so one machine's repeats do not outrank what many machines need", () => {
    const ranked = rankInstalls([readout({ "npm:hono": 50 }), readout({ "npm:zod": 1, "npm:drizzle-orm": 1 }), readout({ "npm:drizzle-orm": 2 })]);
    expect(ranked.map((r) => [r.name, r.machines, r.installs])).toEqual([
      ["drizzle-orm", 2, 3],
      ["hono", 1, 50],
      ["zod", 1, 1],
    ]);
  });

  test("the measured npm list: npm-registry managers, enough machines, not already in base, capped", () => {
    const ranked = rankInstalls(
      [
        readout({ "npm:react": 4, "pnpm:hono": 1, "npm:tailwindcss": 2, "pip:numpy": 3, "npm:one-machine": 7, "bun:vite": 1 }),
        readout({ "npm:react": 1, "bun:hono": 2, "yarn:hono": 1, "npm:tailwindcss": 1, "pip:numpy": 3 }),
      ],
      true,
    );
    // hono: pnpm on one machine, bun and yarn on the other: two machines, four installs.
    expect(ranked.find((r) => r.name === "hono")).toEqual({ manager: "npm", name: "hono", installs: 4, machines: 2 });
    expect(measuredNpm(ranked, ["react"])).toEqual(["hono", "tailwindcss"]);
    expect(measuredNpm(ranked, ["react"], 1)).toEqual(["hono"]);
    expect(measuredNpm(ranked, ["react"], 40, 1)).toContain("one-machine");
    expect(measuredNpm(ranked, [])).not.toContain("numpy");
  });

  test("managers map to their registry", () => {
    expect(["npm", "pnpm", "yarn", "bun", "pip", "uv", "cargo"].map(registryOf)).toEqual(["npm", "npm", "npm", "npm", "pypi", "pypi", "cargo"]);
  });

  test("a readout with no install counts adds nothing", () => {
    expect(rankInstalls([{}, { rollup: {} }, { rollup: { counts: {} } }])).toEqual([]);
  });
});

describe("the baked npm list (prefill-deps.json)", () => {
  test("is base then measured, deduplicated, and every name is an npm registry name", () => {
    expect(prefillNodeDeps({ base: ["react", "zod"], measured: ["zod", "hono"] })).toEqual(["react", "zod", "hono"]);
    for (const name of PREFILL_NODE_DEPS) expect(name).toMatch(NPM_NAME);
    expect(PREFILL_NODE_DEPS.slice(0, 2)).toEqual(["react", "react-dom"]);
  });

  test("refuses a name that is not a registry name, so nothing else reaches the bake's shell", () => {
    expect(() => prefillNodeDeps({ base: [], measured: ["x; rm -rf /"] })).toThrow(/not npm registry names/);
    expect(() => prefillNodeDeps({ base: [], measured: ["./local"] })).toThrow();
    expect(() => prefillNodeDeps({ base: [], measured: ["git+ssh://h/x"] })).toThrow();
  });

  test("the bake's install line installs the list", () => {
    expect(npmCachePrefillCommand()).toContain(`--loglevel=error ${PREFILL_NODE_DEPS.join(" ")}`);
  });
});
