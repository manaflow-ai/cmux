import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { auditDefaultProviderImage } from "../scripts/cloud-vm/defaultProviderAudit.mjs";

type Manifest = {
  images: Array<{
    provider: string;
    version: string;
    imageId: string;
    envVar: string;
    validationStatus: string;
  }>;
};

const realManifest = JSON.parse(
  readFileSync(
    path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "services", "vms", "images", "manifest.json"),
    "utf8",
  ),
) as Manifest;

describe("default provider env coherence audit", () => {
  test("the 2026-08-26 production shape fails: freestyle default with only blaxel-era changes needed", () => {
    // Exact prod state during the outage: default provider flipped in code,
    // never in env, and no BLAXEL_SANDBOX_IMAGE. The old audit passed on this.
    const result = auditDefaultProviderImage(
      {
        FREESTYLE_SANDBOX_SNAPSHOT: "sh-17agfasevrc18c8f15nn",
        FREESTYLE_API_KEY: "x",
      },
      realManifest,
    ) as { provider: string; problems: string[] };
    // With no CMUX_VM_DEFAULT_PROVIDER, the code default (blaxel) applies and
    // its image env plus credentials are missing.
    expect(result.provider).toBe("blaxel");
    expect(result.problems.join("\n")).toContain("BLAXEL_SANDBOX_IMAGE is not set");
    expect(result.problems.join("\n")).toContain("BL_API_KEY");
  });

  test("an image value outside the manifest is a problem", () => {
    const result = auditDefaultProviderImage(
      {
        CMUX_VM_DEFAULT_PROVIDER: "freestyle",
        FREESTYLE_SANDBOX_SNAPSHOT: "sh-not-a-real-snapshot",
        FREESTYLE_API_KEY: "x",
      },
      realManifest,
    ) as { problems: string[] };
    expect(result.problems.join("\n")).toContain("not listed in the image manifest");
  });

  test("a coherent blaxel production env passes", () => {
    const result = auditDefaultProviderImage(
      {
        CMUX_VM_DEFAULT_PROVIDER: "blaxel",
        BLAXEL_SANDBOX_IMAGE: "sandbox/cmux-devbox:latest",
        BL_API_KEY: "x",
        BL_WORKSPACE: "manaflow",
      },
      realManifest,
    ) as { provider: string; envVar: string; problems: string[] };
    expect(result.provider).toBe("blaxel");
    expect(result.envVar).toBe("BLAXEL_SANDBOX_IMAGE");
    expect(result.problems).toEqual([]);
  });

  test("a provider with no manifest entries at all is a problem", () => {
    const result = auditDefaultProviderImage(
      { CMUX_VM_DEFAULT_PROVIDER: "daytona" },
      { images: realManifest.images.filter((entry) => entry.provider !== "daytona") },
    ) as { problems: string[] };
    expect(result.problems.join("\n")).toContain("no entries in the image manifest");
  });

  test("a manifest entry that never passed validation is a problem", () => {
    const result = auditDefaultProviderImage(
      {
        CMUX_VM_DEFAULT_PROVIDER: "freestyle",
        FREESTYLE_SANDBOX_SNAPSHOT: "sh-w2otfp1g287lzrpuc2gr",
        FREESTYLE_API_KEY: "x",
      },
      realManifest,
    ) as { problems: string[] };
    expect(result.problems.join("\n")).toContain("validationStatus");
  });
});

describe("sensitive env placeholders", () => {
  test("a Sensitive default-provider value is itself a problem", () => {
    const result = auditDefaultProviderImage(
      { CMUX_VM_DEFAULT_PROVIDER: "[SENSITIVE]" },
      realManifest,
    ) as { problems: string[] };
    expect(result.problems.join("\n")).toContain("cannot be audited");
  });

  test("a Sensitive image value is itself a problem", () => {
    const result = auditDefaultProviderImage(
      {
        CMUX_VM_DEFAULT_PROVIDER: "blaxel",
        BLAXEL_SANDBOX_IMAGE: "[SENSITIVE]",
        BL_API_KEY: "x",
        BL_WORKSPACE: "manaflow",
      },
      realManifest,
    ) as { problems: string[] };
    expect(result.problems.join("\n")).toContain("cannot be audited");
  });
});
