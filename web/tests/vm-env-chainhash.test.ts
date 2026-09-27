// Shared vectors with cmuxTests/CMUXCLIVMEnvSpecTests.swift — the Swift CLI
// computes chain hashes, so both implementations must produce identical bytes.

import { describe, expect, test } from "bun:test";
import { canonicalStepJSON, envChainHashes } from "../services/vms/envChainHash";

describe("env chain hash (shared vectors with Swift)", () => {
  const env = { FOO: "bar baz", A: "1" };

  test("canonical step JSON sorts env keys and escapes deterministically", () => {
    expect(canonicalStepJSON("echo hello", env)).toBe(
      '{"env":{"A":"1","FOO":"bar baz"},"run":"echo hello"}',
    );
    expect(canonicalStepJSON("apt-get install -y cowsay\nline2", env)).toBe(
      '{"env":{"A":"1","FOO":"bar baz"},"run":"apt-get install -y cowsay\\nline2"}',
    );
    expect(canonicalStepJSON("git clone \"https://x\" && echo 'done'", {})).toBe(
      '{"env":{},"run":"git clone \\"https://x\\" && echo \'done\'"}',
    );
  });

  test("chain hashes match the Swift vectors", () => {
    expect(
      envChainHashes({
        provider: "freestyle",
        baseImageId: "img-1",
        env,
        steps: [{ run: "echo hello" }, { run: "apt-get install -y cowsay\nline2" }],
      }),
    ).toEqual([
      "14ea949a0303c3de1847fd3bc41d68f30ddf5687783691e662365a8b2f4c9c5d",
      "41a20fb093a240d59ff3f27a7a22c938e2efed46980e585dbdbc0f399cd60db6",
    ]);

    expect(
      envChainHashes({
        provider: "freestyle",
        baseImageId: "snap-abc",
        env: {},
        steps: [{ run: "git clone \"https://x\" && echo 'done'" }],
      }),
    ).toEqual(["66eb63edfbe60da8444f9336652f90433883596d54667162dc95b71132055593"]);
  });

  test("a different base image invalidates every layer", () => {
    const stepInput = { provider: "freestyle", env: {}, steps: [{ run: "echo x" }] };
    const a = envChainHashes({ ...stepInput, baseImageId: "img-a" });
    const b = envChainHashes({ ...stepInput, baseImageId: "img-b" });
    expect(a[0]).not.toBe(b[0]);
  });
});
