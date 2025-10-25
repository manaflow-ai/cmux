import { describe, expect, it } from "vitest";
import { generateWorkspaceName } from "./generate-workspace-name";

describe("generateWorkspaceName", () => {
  it("combines repo name with alphabetical suffix", () => {
    expect(
      generateWorkspaceName({ repoName: "awesome-repo", sequence: 0 }),
    ).toBe("awesome-repo-a");
  });

  it("sanitizes repo name and lowercases it", () => {
    expect(
      generateWorkspaceName({ repoName: "My Repo!", sequence: 1 }),
    ).toBe("my-repo-b");
  });

  it("falls back to workspace prefix when repo is missing", () => {
    expect(generateWorkspaceName({ sequence: 2 })).toBe("workspace-c");
  });

  it("supports multi-letter suffixes", () => {
    expect(
      generateWorkspaceName({ repoName: "example", sequence: 27 }),
    ).toBe("example-ab");
  });
});
