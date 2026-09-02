import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  ALERT_SINK_KEY,
  ALERT_SINK_UNCONFIGURED_ACK_KEY,
  alertSinkAuditEnvKeys,
  auditAlertSink,
} from "../scripts/cloud-vm/alertSinkAudit.mjs";
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
  legacyCloudVmEnvKeys,
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
    kind?: string;
    defaultForKind?: boolean;
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

// The manifest's validated base default (defaultForKind): what deployed
// runtimes serve when FREESTYLE_SANDBOX_SNAPSHOT is unset.
const freestyleBaseDefault = realManifest.images.find(
  (entry) => entry.provider === "freestyle" && (entry.kind ?? "base") === "base" && entry.defaultForKind,
)!;

describe("cloud VM provider coherence audit", () => {
  test("an env default naming a removed provider fails on the code-default leg", () => {
    // The 2026-08-26 outage shape, and now also the stale-env shape: the
    // deployed CMUX_VM_DEFAULT_PROVIDER still names a provider that has been
    // removed, while shipped clients send the code default's image ids. The
    // manifest default covers the missing snapshot env var; the missing API
    // key still makes the code default unprovisionable.
    const result = auditCloudVmProviderCoherence(
      { CMUX_VM_DEFAULT_PROVIDER: "e2b" },
      realManifest,
    ) as Coherence;
    expect(result.selected?.provider).toBe("e2b");
    expect(result.codeDefault?.provider).toBe("freestyle");
    expect(result.codeDefault).toMatchObject({ image: freestyleBaseDefault.imageId, imageSource: "manifest" });
    expect(result.problems.join("\n")).toContain("FREESTYLE_API_KEY is not set");
  });

  test("no default provider set means the code default (freestyle) must be ready", () => {
    const result = auditCloudVmProviderCoherence(
      {},
      realManifest,
    ) as Coherence;
    expect(result.selected?.provider).toBe("freestyle");
    expect(result.codeDefault).toBeNull();
    expect(result.selected).toMatchObject({ image: freestyleBaseDefault.imageId, imageSource: "manifest" });
    expect(result.problems.join("\n")).toContain("FREESTYLE_API_KEY");
  });

  test("the manifest's validated base default is the deployed image", () => {
    // The committed manifest is the only source of truth (resolver
    // defaultForKind). A clean env is one with the API key set.
    const result = auditProviderReadiness("freestyle", { FREESTYLE_API_KEY: "x" }, realManifest) as {
      image: string | null;
      imageSource: string;
      problems: string[];
    };
    expect(result).toMatchObject({ image: freestyleBaseDefault.imageId, imageSource: "manifest", problems: [] });
  });

  test("a manifest without a validated base default fails closed", () => {
    const stripped = {
      images: realManifest.images.map((entry) => ({ ...entry, defaultForKind: false })),
    };
    const result = auditProviderReadiness("freestyle", { FREESTYLE_API_KEY: "x" }, stripped) as {
      problems: string[];
    };
    expect(result.problems.join("\n")).toContain("the manifest has no validated base default for freestyle");
    const unvalidated = {
      images: realManifest.images.map((entry) =>
        entry.defaultForKind ? { ...entry, validationStatus: "unknown" } : entry,
      ),
    };
    const bad = auditProviderReadiness("freestyle", { FREESTYLE_API_KEY: "x" }, unvalidated) as {
      image: string | null;
      problems: string[];
    };
    expect(bad.problems.join("\n")).toMatch(/manifest default .* has validationStatus unknown, not passed/);
    expect(bad.problems.join("\n")).toContain("the manifest has no validated base default for freestyle");
    expect(bad.image).toBeNull();
  });

  test("the validated public-platform freestyle devbox passes as the default provider", () => {
    const result = auditCloudVmProviderCoherence(
      {
        CMUX_VM_DEFAULT_PROVIDER: "freestyle",
        CMUX_VM_FREESTYLE_ENABLED: "1",
        FREESTYLE_API_KEY: "x",
      },
      realManifest,
    ) as Coherence;
    expect(result.selected?.provider).toBe("freestyle");
    expect(result.codeDefault).toBeNull();
    expect(result.problems).toEqual([]);
  });

  test("a disabled Freestyle flag fails the selected default audit", () => {
    const result = auditCloudVmProviderCoherence(
      {
        CMUX_VM_DEFAULT_PROVIDER: "freestyle",
        CMUX_VM_FREESTYLE_ENABLED: "0",
        FREESTYLE_API_KEY: "x",
      },
      realManifest,
    ) as Coherence;
    expect(result.problems.join("\n")).toContain("CMUX_VM_FREESTYLE_ENABLED disables provider freestyle");
  });

  test("a lingering FREESTYLE_SANDBOX_SNAPSHOT is stale configuration, whatever it names", () => {
    // No env var selects an image any more: the manifest is the only source
    // of truth. A leftover selector (even one naming a valid entry) would
    // mislead whoever reads the deployment, so the audit asks for its removal.
    for (const value of ["sh-940ec3bc46224c019e5e8d9a97053293", "sh-fb3dcf7b47894114889b10186626af5b", "sh-not-a-real-snapshot"]) {
      const result = auditCloudVmProviderCoherence(
        { CMUX_VM_DEFAULT_PROVIDER: "freestyle", FREESTYLE_SANDBOX_SNAPSHOT: value, FREESTYLE_API_KEY: "x" },
        realManifest,
      ) as Coherence;
      expect(result.selected?.provider).toBe("freestyle");
      expect(result.problems.join("\n")).toContain("FREESTYLE_SANDBOX_SNAPSHOT is set but ignored");
    }
  });

  test("a provider with no manifest entries at all is a problem", () => {
    const result = auditProviderReadiness(
      "freestyle",
      {},
      { images: realManifest.images.filter((entry) => entry.provider !== "freestyle") },
    ) as { problems: string[] };
    expect(result.problems.join("\n")).toContain("no entries in the image manifest");
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
        CMUX_VM_DEFAULT_PROVIDER: "freestyle",
        FREESTYLE_SANDBOX_SNAPSHOT: "[SENSITIVE]",
        FREESTYLE_API_KEY: "x",
      },
      realManifest,
    ) as Coherence;
    expect(result.problems.join("\n")).toContain("FREESTYLE_SANDBOX_SNAPSHOT is set but ignored");
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
  test("freestyle credentials, cron auth, and the alert sink are required", () => {
    for (const key of [
      "FREESTYLE_API_KEY",
      "CMUX_VM_FREESTYLE_ENABLED",
      "CRON_SECRET",
      "CMUX_ALERTS_SLACK_WEBHOOK_URL",
    ]) {
      expect(requiredRuntimeEnvKeys).toContain(key);
    }
  });

  test("no removed provider's env keys are still demanded", () => {
    for (const key of [
      "BL_API_KEY", "BL_WORKSPACE", "BLAXEL_SANDBOX_IMAGE", "BLAXEL_SANDBOX_DESKTOP_IMAGE", "CMUX_VM_BLAXEL_ENABLED",
      "E2B_API_KEY", "E2B_CMUXD_WS_TEMPLATE", "E2B_SANDBOX_TEMPLATE", "CMUX_VM_E2B_ENABLED",
      "DAYTONA_API_KEY", "DAYTONA_API_URL", "DAYTONA_SANDBOX_SNAPSHOT", "CMUX_VM_DAYTONA_ENABLED",
    ]) {
      expect(requiredRuntimeEnvKeys).not.toContain(key);
      expect(recommendedRuntimeEnvKeys).not.toContain(key);
      expect(legacyCloudVmEnvKeys).toContain(key);
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

  test("the alert-sink acknowledgement is never required or recommended", () => {
    for (const key of alertSinkAuditEnvKeys) {
      expect(requiredRuntimeEnvKeys).not.toContain(key);
      expect(recommendedRuntimeEnvKeys).not.toContain(key);
    }
  });
});

describe("alert sink audit", () => {
  const webhook = "https://hooks.slack.com/services/T0/B0/x";
  const ack = "no Slack webhook provisioned; dropped alerts reach Sentry/PostHog. lawrence 2026-09-01";

  test("a configured sink waives nothing and has no problems", () => {
    const result = auditAlertSink({ [ALERT_SINK_KEY]: webhook });
    expect(result.configured).toBe(true);
    expect(result.acknowledged).toBe(false);
    expect(result.waivedRequiredKeys).toEqual([]);
    expect(result.problems).toEqual([]);
  });

  test("neither key waives nothing, so the sink stays missing-required", () => {
    const result = auditAlertSink({});
    expect(result.configured).toBe(false);
    expect(result.waivedRequiredKeys).toEqual([]);
    expect(result.problems).toEqual([]);
  });

  test("a recorded acknowledgement waives the sink and exposes the reason", () => {
    const result = auditAlertSink({ [ALERT_SINK_UNCONFIGURED_ACK_KEY]: ` ${ack} ` });
    expect(result.acknowledged).toBe(true);
    expect(result.reason).toBe(ack);
    expect(result.waivedRequiredKeys).toEqual([ALERT_SINK_KEY]);
    expect(result.problems).toEqual([]);
  });

  test("an empty or Sensitive acknowledgement fails instead of waiving", () => {
    for (const value of ["", "   ", "[SENSITIVE]"]) {
      const result = auditAlertSink({ [ALERT_SINK_UNCONFIGURED_ACK_KEY]: value });
      expect(result.waivedRequiredKeys).toEqual([]);
      expect(result.problems.length).toBe(1);
      expect(result.problems[0]).toContain(ALERT_SINK_UNCONFIGURED_ACK_KEY);
    }
  });

  test("an acknowledgement next to a configured sink is a stale-config problem", () => {
    const result = auditAlertSink({
      [ALERT_SINK_KEY]: webhook,
      [ALERT_SINK_UNCONFIGURED_ACK_KEY]: ack,
    });
    expect(result.configured).toBe(true);
    expect(result.waivedRequiredKeys).toEqual([]);
    expect(result.problems.join("\n")).toContain("stale");
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
