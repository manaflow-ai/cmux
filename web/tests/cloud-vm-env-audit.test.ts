import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  auditCloudVmProviderCoherence,
  auditProviderReadiness,
  CODE_DEFAULT_PROVIDER,
} from "../scripts/cloud-vm/defaultProviderAudit.mjs";
import {
  auditFreeProvisioningOverride,
  freeProvisioningOverrideEnvKeys,
  isFreeProvisioningAllowed,
} from "../scripts/cloud-vm/freeProvisioningAudit.mjs";
import {
  recommendedRuntimeEnvKeys,
  requiredRuntimeEnvKeys,
} from "../scripts/cloud-vm/projects.mjs";
import { defaultProviderId } from "../services/vms/drivers";
import { isVmFreeProvisioningAllowed } from "../services/vms/entitlements";

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

describe("audit constants stay tied to the runtime", () => {
  test("CODE_DEFAULT_PROVIDER matches defaultProviderId() with no env override", () => {
    // The audit script cannot import the runtime driver module (it must stay
    // a dependency-free .mjs for CI), so this test enforces the pairing: if
    // defaultProviderId()'s fallback changes, this fails until the audit's
    // CODE_DEFAULT_PROVIDER moves with it.
    const saved = process.env.CMUX_VM_DEFAULT_PROVIDER;
    delete process.env.CMUX_VM_DEFAULT_PROVIDER;
    try {
      expect(CODE_DEFAULT_PROVIDER).toBe(defaultProviderId());
    } finally {
      if (saved !== undefined) process.env.CMUX_VM_DEFAULT_PROVIDER = saved;
    }
  });

  test("a provider without a credential mapping fails closed", () => {
    const manifest = {
      images: [{
        provider: "newprovider",
        version: "newprovider-v1",
        imageId: "np:latest",
        envVar: "NEWPROVIDER_IMAGE",
        validationStatus: "passed",
      }],
    };
    const result = auditProviderReadiness(
      "newprovider",
      { NEWPROVIDER_IMAGE: "np:latest" },
      manifest,
    ) as { problems: string[] };
    expect(result.problems.join("\n")).toContain("no credential mapping");
  });
});

describe("required runtime env keys cover the production provider path", () => {
  test("blaxel credentials, cron auth, and the alert sink are required", () => {
    for (const key of [
      "BL_API_KEY",
      "BL_WORKSPACE",
      "BLAXEL_SANDBOX_IMAGE",
      "CRON_SECRET",
      "CMUX_ALERTS_SLACK_WEBHOOK_URL",
    ]) {
      expect(requiredRuntimeEnvKeys).toContain(key);
    }
  });

  test("off-only kill switches and the desktop selector stay recommended, not required", () => {
    // Unset means enabled for kill switches, and desktop creates fall back to
    // the generic BLAXEL_SANDBOX_IMAGE selector, so requiring these would
    // fail a healthy deployment.
    for (const key of ["CMUX_VM_BLAXEL_ENABLED", "BLAXEL_SANDBOX_DESKTOP_IMAGE"]) {
      expect(recommendedRuntimeEnvKeys).toContain(key);
      expect(requiredRuntimeEnvKeys).not.toContain(key);
    }
  });

  test("the free-provisioning escape hatch is never required or recommended", () => {
    // Unset is the safe value; listing it for presence would nudge operators
    // into setting it. Its VALUE is audited instead (see below).
    for (const key of freeProvisioningOverrideEnvKeys) {
      expect(requiredRuntimeEnvKeys).not.toContain(key);
      expect(recommendedRuntimeEnvKeys).not.toContain(key);
    }
  });
});

describe("free-provisioning override audit", () => {
  type Audit = { present: string[]; allowed: boolean; problems: string[] };

  test("an unset override is clean", () => {
    const result = auditFreeProvisioningOverride({}) as Audit;
    expect(result).toEqual({ present: [], allowed: false, problems: [] });
  });

  test("an explicit off value is clean", () => {
    for (const env of [
      { CMUX_VM_ALLOW_FREE_PROVISIONING: "0" },
      { CMUX_VM_ALLOW_FREE_PROVISIONING: "false" },
      { CMUX_VM_REQUIRE_PRO: "1" },
      // The new switch wins over a stale permissive legacy value.
      { CMUX_VM_ALLOW_FREE_PROVISIONING: "0", CMUX_VM_REQUIRE_PRO: "0" },
    ]) {
      expect((auditFreeProvisioningOverride(env) as Audit).problems).toEqual([]);
    }
  });

  test("a permissive value fails the audit, not just a note", () => {
    const result = auditFreeProvisioningOverride({ CMUX_VM_ALLOW_FREE_PROVISIONING: "1" }) as Audit;
    expect(result.allowed).toBe(true);
    expect(result.problems.join("\n")).toContain("free Cloud VM provisioning is enabled");
    expect(result.problems.join("\n")).toContain("CMUX_VM_ALLOW_FREE_PROVISIONING=1");
  });

  test("a lone legacy CMUX_VM_REQUIRE_PRO=0 is the same outage", () => {
    const result = auditFreeProvisioningOverride({ CMUX_VM_REQUIRE_PRO: "0" }) as Audit;
    expect(result.allowed).toBe(true);
    expect(result.problems.join("\n")).toContain("legacy CMUX_VM_REQUIRE_PRO=0");
  });

  test("a Sensitive override value cannot be audited and fails", () => {
    const result = auditFreeProvisioningOverride({ CMUX_VM_ALLOW_FREE_PROVISIONING: "[SENSITIVE]" }) as Audit;
    expect(result.allowed).toBe(false);
    expect(result.problems.join("\n")).toContain("cannot be audited");
  });

  test("the audit mirrors the runtime gate decision exactly", () => {
    // The .mjs cannot import the TypeScript runtime, so this pins the copy of
    // the flag semantics to the real predicate across every accepted spelling.
    const values = [undefined, "", "1", "0", "true", "false", "yes", "no", "on", "off", "enabled", "disabled", "TRUE ", " Off", "maybe"];
    for (const allow of values) {
      for (const legacy of values) {
        const env: Record<string, string | undefined> = {};
        if (allow !== undefined) env.CMUX_VM_ALLOW_FREE_PROVISIONING = allow;
        if (legacy !== undefined) env.CMUX_VM_REQUIRE_PRO = legacy;
        expect(isFreeProvisioningAllowed(env)).toBe(isVmFreeProvisioningAllowed(env));
      }
    }
  });
});
