// Microsoft Foundry runs OpenCode but keeps its own picker tab (not an OpenCode route).
import { expect, test } from "bun:test";
import { chipFace, providerMark } from "../src/agent-session/acpmux/chipFace";
import { catalogModel, normalizeCatalog } from "../src/agent-session/acpmux/direct/catalog";
import { modelIdName, withoutByoPrefix } from "../src/agent-session/acpmux/defaultChoice";
import { INSTALL_COMMANDS, installCommand } from "../src/agent-session/acpmux/harnesses/harnessRows";
import {
  BUNDLED_MODEL_CATALOG,
  buildPickerCatalog,
  FOUNDRY_HARNESS,
} from "../src/agent-session/acpmux/modelCatalogData";

const t = ((key: string) => key) as never;
const foundry = (extra: Record<string, unknown> = {}) => ({
  id: FOUNDRY_HARNESS,
  name: "Microsoft Foundry",
  family: "opencode",
  models: [{ id: "azure/gpt-4o", name: "gpt-4o" }],
  ...extra,
});

test("a string id from a profile's models list keeps that id, and programMissing only when true", () => {
  expect(catalogModel("byo/gpt-4o")).toEqual({ id: "byo/gpt-4o", name: undefined });
  expect(catalogModel({ id: "byo/gpt-4o-mini", name: "GPT-4o mini" })).toEqual({
    id: "byo/gpt-4o-mini",
    name: "GPT-4o mini",
  });
  const catalog = normalizeCatalog({
    harnesses: {
      foundry: {
        family: "opencode",
        models: ["byo/gpt-4o", { id: "byo/gpt-5", name: "gpt-5" }],
        programMissing: true,
      },
      opencode: { family: "opencode", models: [], programMissing: false },
    },
  });
  expect(catalog.find((entry) => entry.id === "foundry")?.models.map((m) => m.id)).toEqual(["byo/gpt-4o", "byo/gpt-5"]);
  expect(catalog.find((entry) => entry.id === "foundry")?.programMissing).toBe(true);
  expect(catalog.find((entry) => entry.id === "opencode")?.programMissing).toBeUndefined();
});

test("Foundry is its own picker harness, not an OpenCode route", () => {
  const joined = buildPickerCatalog({
    catalog: BUNDLED_MODEL_CATALOG,
    acpmux: [
      {
        id: "opencode",
        name: "OpenCode",
        family: "opencode",
        models: [{ id: "opencode/gpt-5", name: "GPT-5" }],
      },
      foundry({
        icon: "foundry.png",
        models: [
          { id: "azure/gpt-4o", name: "gpt-4o" },
          { id: "azure/gpt-5", name: "gpt-5" },
        ],
      }),
    ],
  });
  const entry = joined.harnesses.find((harness) => harness.id === FOUNDRY_HARNESS)!;
  expect(entry.name).toBe("Microsoft Foundry");
  expect(entry.models.map((model) => model.id)).toEqual(["azure/gpt-4o", "azure/gpt-5"]);
  expect(
    joined.harnesses.find((harness) => harness.id === "opencode")!.models.some((m) => m.id.startsWith("azure/")),
  ).toBe(false);
  expect(joined.harnesses.filter((harness) => harness.id === FOUNDRY_HARNESS)).toHaveLength(1);
  expect(entry.installed).toBe(true);
});

test("Foundry with no OpenCode on this Mac is not installed, and installs OpenCode", () => {
  const joined = buildPickerCatalog({
    catalog: BUNDLED_MODEL_CATALOG,
    acpmux: [foundry({ programMissing: true })],
  });
  const entry = joined.harnesses.find((harness) => harness.id === FOUNDRY_HARNESS)!;
  expect(entry.installed).toBe(false);
  expect(entry.pickable).toBe(true);
  expect(installCommand(FOUNDRY_HARNESS, entry.family)).toBe(INSTALL_COMMANDS.opencode);
  expect(installCommand("claude")).toBe(INSTALL_COMMANDS.claude);
  expect(installCommand("my-agent", "unknown-family")).toBeUndefined();
});

test("a Foundry model keeps Foundry's mark and drops its provider prefix", () => {
  expect(providerMark("azure/gpt-4o")).toBe("openai");
  expect(chipFace("azure/gpt-4o", "gpt-4o", "foundry").mark).toBe("foundry");
  expect(chipFace("byo/gpt-4o", "gpt-4o", "foundry").mark).toBe("foundry");
  expect(chipFace("claude-opus-5-5", "Opus 5.5", "codex").mark).toBe("claude");
  expect(withoutByoPrefix("azure/gpt-4o")).toBe("gpt-4o");
  expect(withoutByoPrefix("byo/gpt-4o")).toBe("gpt-4o");
  expect(modelIdName("azure/gpt-4o", t)).toBe("gpt-4o");
  expect(modelIdName("byo/gpt-4o", t)).toBe("gpt-4o");
});
