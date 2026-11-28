// The Add project palette's Git URL with Cloud picked (cloudGitURLFolder): the probe's GitHub URL and GitLab URL
// cells ended `no_git_url` because Cloud offered no Git URL row. A GitHub URL is the chat's `github:owner/name`; any
// other host is refused in words, since the app's Cloud start carries a GitHub repository only.
import { describe, expect, test } from "bun:test";
import { cloudGitURLFolder } from "../src/agent-session/acpmux/sourcePickerModel";

describe("cloudGitURLFolder", () => {
  for (const url of [
    "https://github.com/octocat/Hello-World",
    "https://github.com/octocat/Hello-World.git",
    "https://github.com/octocat/Hello-World/",
    "git@github.com:octocat/Hello-World.git",
    "  https://github.com/octocat/Hello-World  ",
    "octocat/Hello-World",
  ])
    test(`a GitHub repository: ${url.trim()}`, () => {
      expect(cloudGitURLFolder(url)).toEqual({ folder: "github:octocat/Hello-World" });
    });

  test("another host's https URL is refused as GitHub-only", () => {
    expect(cloudGitURLFolder("https://gitlab.com/gitlab-org/gitlab-test")).toEqual({
      error: "source.url.cloudGitHubOnly",
    });
  });

  test("a URL with credentials or a bad form says why", () => {
    expect(cloudGitURLFolder("https://tok@gitlab.com/a/b")).toEqual({ error: "source.url.credentials" });
    expect(cloudGitURLFolder("http://gitlab.com/a/b")).toEqual({ error: "source.url.invalid" });
    expect(cloudGitURLFolder("https://github.com/octocat")).toEqual({ error: "source.url.invalid" });
  });
});
