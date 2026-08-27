import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  auditCloudVmProviderCoherence,
  auditProviderReadiness,
} from "../scripts/cloud-vm/defaultProviderAudit.mjs";

type Manifest = {
  images: Array<{
    provider: string;
    version: string;
    imageId: string;
    envVar: string;
    validationStatus: string;
  }>;
};

type Coherence = {
  selected: { provider: string } | null;
  codeDefault: { provider: string } | null;
  problems: string[];
};

const realManifest = JSON.parse(
  readFileSync(
    path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "services", "vms", "images", "manifest.json"),
    "utf8",
  ),
) as Manifest;

describe("cloud VM provider coherence audit", () => {
  test("the exact 2026-08-26 production env fails on the code-default leg", () => {
    // Prod state during the outage: a fully coherent freestyle default, while
    // shipped CLIs hardcode blaxel image ids and no blaxel env existed. The
    // old key-presence audit passed this env.
    const result = auditCloudVmProviderCoherence(
      {
        CMUX_VM_DEFAULT_PROVIDER: "freestyle",
        FREESTYLE_SANDBOX_SNAPSHOT: "sh-17agfasevrc18c8f15nn",
        FREESTYLE_API_KEY: "x",
        BL_API_KEY: "x",
        BL_WORKSPACE: "manaflow",
      },
      realManifest,
    ) as Coherence;
    expect(result.selected?.provider).toBe("freestyle");
    expect(result.codeDefault?.provider).toBe("blaxel");
    expect(result.problems.join("\n")).toContain("BLAXEL_SANDBOX_IMAGE is not set");
  });

  test("no default provider set means the code default (blaxel) must be ready", () => {
    const result = auditCloudVmProviderCoherence(
      { FREESTYLE_SANDBOX_SNAPSHOT: "sh-17agfasevrc18c8f15nn", FREESTYLE_API_KEY: "x" },
      realManifest,
    ) as Coherence;
    expect(result.selected?.provider).toBe("blaxel");
    expect(result.codeDefault).toBeNull();
    expect(result.problems.join("\n")).toContain("BLAXEL_SANDBOX_IMAGE is not set");
    expect(result.problems.join("\n")).toContain("BL_API_KEY");
  });

  test("a coherent blaxel production env passes", () => {
    const result = auditCloudVmProviderCoherence(
      {
        CMUX_VM_DEFAULT_PROVIDER: "blaxel",
        BLAXEL_SANDBOX_IMAGE: "sandbox/cmux-devbox:latest",
        BL_API_KEY: "x",
        BL_WORKSPACE: "manaflow",
      },
      realManifest,
    ) as Coherence;
    expect(result.selected?.provider).toBe("blaxel");
    expect(result.codeDefault).toBeNull();
    expect(result.problems).toEqual([]);
  });

  test("a deliberate freestyle rollback passes only with blaxel still provisionable", () => {
    const rollbackEnv = {
      CMUX_VM_DEFAULT_PROVIDER: "freestyle",
      FREESTYLE_SANDBOX_SNAPSHOT: "sh-17agfasevrc18c8f15nn",
      FREESTYLE_API_KEY: "x",
      BLAXEL_SANDBOX_IMAGE: "sandbox/cmux-devbox:latest",
      BL_API_KEY: "x",
      BL_WORKSPACE: "manaflow",
    };
    const result = auditCloudVmProviderCoherence(rollbackEnv, realManifest) as Coherence;
    expect(result.problems).toEqual([]);
    expect(result.codeDefault?.provider).toBe("blaxel");
  });

  test("an image value outside the manifest is a problem", () => {
    const result = auditProviderReadiness(
      "freestyle",
      { FREESTYLE_SANDBOX_SNAPSHOT: "sh-not-a-real-snapshot", FREESTYLE_API_KEY: "x" },
      realManifest,
    ) as { problems: string[] };
    expect(result.problems.join("\n")).toContain("not listed in the image manifest");
  });

  test("a provider with no manifest entries at all is a problem", () => {
    const result = auditProviderReadiness(
      "daytona",
      {},
      { images: realManifest.images.filter((entry) => entry.provider !== "daytona") },
    ) as { problems: string[] };
    expect(result.problems.join("\n")).toContain("no entries in the image manifest");
  });

  test("a manifest entry that never passed validation is a problem", () => {
    const result = auditProviderReadiness(
      "freestyle",
      { FREESTYLE_SANDBOX_SNAPSHOT: "sh-w2otfp1g287lzrpuc2gr", FREESTYLE_API_KEY: "x" },
      realManifest,
    ) as { problems: string[] };
    expect(result.problems.join("\n")).toContain("validationStatus");
  });
});

describe("sensitive env placeholders", () => {
  test("a Sensitive default-provider value is itself a problem", () => {
    const result = auditCloudVmProviderCoherence(
      { CMUX_VM_DEFAULT_PROVIDER: "[SENSITIVE]" },
      realManifest,
    ) as Coherence;
    expect(result.problems.join("\n")).toContain("cannot be audited");
  });

  test("a Sensitive image value is itself a problem", () => {
    const result = auditCloudVmProviderCoherence(
      {
        CMUX_VM_DEFAULT_PROVIDER: "blaxel",
        BLAXEL_SANDBOX_IMAGE: "[SENSITIVE]",
        BL_API_KEY: "x",
        BL_WORKSPACE: "manaflow",
      },
      realManifest,
    ) as Coherence;
    expect(result.problems.join("\n")).toContain("cannot be audited");
  });
});
