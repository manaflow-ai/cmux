import { expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
  expect(workflow).toContain('CMUX_TEAM: "team_0f3a"');
  expect(workflow).not.toContain("uses:");
  expect(workflowSnippet(null, null)).toContain('CMUX_TEAM: ""');
});

test("the copied workflow exchanges OIDC, masks credentials, and refuses failed exchanges", () => {
  const snippet = workflowSnippet("team_0f3a", "https://platform.example");
  const script = snippet
    .split("        run: |\n")[1]
    .split("\n")
    .map((line) => line.slice(10))
    .join("\n");
  const directory = mkdtempSync(join(tmpdir(), "cmux-token-workflow-"));
  const token = `cmux_pat_${"a".repeat(50)}`;
  // Run the copied shell, with only HTTP stubbed. jq still parses the actual request and response.
  const http = `curl() {
    case "$*" in
      *'https://github.example/token?request=1&audience=cmux'*)
        [ "$MODE" != oidc-failed ] || return 22
        printf '%s' '{"value":"github-identity"}' ;;
      *'https://platform.example/v1/tokens/github/exchange'*)
        [ "$MODE" != exchange-failed ] || return 22
        printf '%s' "\${!#}" | jq -e --arg team "$CMUX_TEAM" '.idToken == "github-identity" and (if $team == "" then (has("team") | not) else .team == $team end)' >/dev/null || return 1
        if [ "$MODE" = missing-token ]; then printf '%s' '{}';
        elif [ "$MODE" = malformed-token ]; then printf '%s' '{"token":"bad token"}';
        else printf '%s' '{"token":"${token}"}'; fi ;;
      *) return 1 ;;
    esac
  }`;
  try {
    for (const mode of ["success", "oidc-failed", "exchange-failed", "missing-token", "malformed-token"]) {
      for (const team of ["team_0f3a", ""]) {
        const output = join(directory, `${mode}-${team || "auto"}`);
        const result = Bun.spawnSync(["bash", "-c", `${http}\n${script}`], {
          env: {
            ...process.env,
            MODE: mode,
            CMUX_TEAM: team,
            CMUX_PLATFORM: "https://platform.example",
            ACTIONS_ID_TOKEN_REQUEST_TOKEN: "request-token",
            ACTIONS_ID_TOKEN_REQUEST_URL: "https://github.example/token?request=1",
            GITHUB_ENV: output,
          },
        });
        if (mode === "success") {
          expect(result.exitCode).toBe(0);
          expect(readFileSync(output, "utf8")).toBe(`CMUX_TOKEN=${token}\n`);
          expect(result.stdout.toString()).toBe(`::add-mask::github-identity\n::add-mask::${token}\n`);
        } else {
          expect(result.exitCode).not.toBe(0);
          expect(existsSync(output)).toBe(false);
          expect(result.stdout.toString()).not.toContain(token);
        }
      }
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
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
