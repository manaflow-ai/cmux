import { expect, test } from "bun:test";
import "./testCatalog";
import {
  branchOf,
  curlExample,
  expiresText,
  exportLine,
  lastUsedText,
  refOf,
  repositoryOf,
  spendCapOf,
  workflowSnippet,
} from "./tokens";

const NOW = Date.parse("2026-11-25T18:00:00Z");

// Settings > Developer reads a token's end and last use the way a person says them.
test("a token's expiry and last use read plainly", () => {
  expect(expiresText({ expiresAt: null }, NOW, "en")).toBe("Never expires");
  expect(expiresText({ expiresAt: "2026-11-01T00:00:00Z" }, NOW, "en")).toBe("Expired");
  expect(expiresText({ expiresAt: "2027-03-02T12:00:00Z" }, NOW, "en")).toBe("Expires Mar 2, 2027");
  expect(lastUsedText(null, NOW, "en")).toBe("Never used");
  expect(lastUsedText(new Date(NOW - 20_000).toISOString(), NOW, "en")).toBe("Used just now");
  expect(lastUsedText(new Date(NOW - 2 * 3_600_000).toISOString(), NOW, "en")).toBe("Used 2 hours ago");
  expect(lastUsedText(new Date(NOW - 3 * 86_400_000).toISOString(), NOW, "en")).toBe("Used 3 days ago");
});

// The lines shown once after Create Token: what a person pastes next.
test("a new token's paste lines", () => {
  expect(exportLine("cmux_pat_x")).toBe("export CMUX_TOKEN='cmux_pat_x'");
  expect(exportLine("cmux pat'x")).toBe("export CMUX_TOKEN='cmux pat'\"'\"'x'");
  expect(curlExample(["machines"], "https://platform.example/")).toBe(
    'curl -H "Authorization: Bearer $CMUX_TOKEN" https://platform.example/v1/machines',
  );
  // A token that cannot list machines gets no example that would answer 403.
  expect(curlExample(["usage"], null)).toBeNull();
  const workflow = workflowSnippet("team_0f3a", "https://platform.example");
  expect(workflow).toContain("id-token: write");
  expect(workflow).toContain("team: team_0f3a");
  expect(workflowSnippet(null, null)).not.toContain("with:");
});

// Allow Repository takes what a person pastes: owner/name, a GitHub URL, a branch name.
test("repository and branch fields", () => {
  expect(repositoryOf(" acme/web ")).toBe("acme/web");
  expect(repositoryOf("https://github.com/acme/web.git")).toBe("acme/web");
  expect(repositoryOf("acme")).toBeNull();
  expect(repositoryOf("acme/web/extra")).toBeNull();
  expect(refOf("main")).toBe("refs/heads/main");
  expect(refOf("refs/tags/v1")).toBe("refs/tags/v1");
  expect(refOf("  ")).toBeUndefined();
  expect(branchOf("refs/heads/release/*")).toBe("release/*");
  expect(spendCapOf("$50")).toBe(50);
  expect(spendCapOf("1000000.00")).toBe(1_000_000);
  expect(spendCapOf("1000000.01")).toBe(1_000_000.01);
  expect(spendCapOf("0.50")).toBe(0.5);
  expect(spendCapOf("90071992547409.91")).toBe(90071992547409.91);
  expect(spendCapOf("90071992547409.92")).toBeNull();
  expect(spendCapOf("0")).toBeNull();
  expect(spendCapOf("")).toBeNull();
});
