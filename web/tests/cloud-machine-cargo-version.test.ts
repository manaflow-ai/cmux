import { describe, expect, test } from "bun:test";
import { resolveCargoPackageVersion } from "../scripts/build-cloud-vm-images";

describe("Cloud machine Cargo version resolution", () => {
  test("reads version from the package table instead of another table", () => {
    const manifest = `
[dependencies]
version = "9.9.9"

[package]
name = "cmux-tui"
version = "0.1.0"
`;

    expect(resolveCargoPackageVersion(manifest)).toBe("0.1.0");
  });

  test("resolves a workspace package version", () => {
    const packageManifest = `
[package]
name = "cmux-tui"
version.workspace = true
`;
    const workspaceManifest = `
[workspace.package]
version = "0.2.0"
`;

    expect(resolveCargoPackageVersion(packageManifest, workspaceManifest)).toBe("0.2.0");
  });
});
