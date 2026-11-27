// l10n-allow-file: test fixtures, not shipped UI.
// Every phase of the repository recovery card offers a one-click next step (or says what it waits
// for, with its ETA); none is a dead end (Leo, 2026-11-09: "the ergonomic part is super big for us").
// A missing link and an install GitHub hasn't reported are asked again on their own, so they offer no
// Try again or Check again (Leo, 2026-11-22: "vacuous decisions like that should be just done").
import { describe, expect, test } from "bun:test";
import {
  repoRecoveryView,
  waitLeft,
  type RepoRecovery,
  type RepoRecoveryPhase,
  type RepoRecoveryView,
} from "./repoRecoveryCardModel";

const retry = {
  action: "cloud.repo.add",
  args: { session: "s", repo: "acme/demo" },
  wait_action: "cloud.repo.wait_github",
};
const needsGithub: RepoRecovery = {
  code: "repo.needs_github",
  installUrl: "https://github.com/apps/cmux/installations/new",
  retry,
};
const needsGithubNoUrl: RepoRecovery = { code: "repo.needs_github", retry };

const ids = (view: RepoRecoveryView | undefined) => view?.actions.map((action) => action.id);
const key = (view: RepoRecoveryView | undefined) => (view && "key" in view.message ? view.message.key : undefined);

describe("repository recovery: phase to next step", () => {
  test("needs GitHub with a link: explains the gap in task terms and offers Connect", () => {
    const view = repoRecoveryView(needsGithub, { kind: "idle" });
    expect(key(view)).toBe("cloudRepository.connectNeeded");
    expect(view?.message).toEqual({
      key: "cloudRepository.connectNeeded",
      values: { target: { literal: "acme/demo" } },
    });
    expect(ids(view)).toEqual(["connect"]);
  });

  test("needs GitHub without a link: Connect fetches one instead of showing text alone", () => {
    const view = repoRecoveryView(needsGithubNoUrl, { kind: "idle" });
    expect(ids(view)).toEqual(["getLink"]);
    expect(view?.actions[0]?.label).toEqual({ key: "cloudRepository.connect" });
  });

  test("no link anywhere: reads as getting one, no button; past the deadline one quiet still-trying line", () => {
    const view = repoRecoveryView(needsGithubNoUrl, { kind: "noLink" });
    expect(view?.tone).toBe("quiet");
    expect(key(view)).toBe("cloudRepository.linking");
    expect(ids(view)).toEqual([]);
    const late = repoRecoveryView(needsGithubNoUrl, { kind: "noLink" }, undefined, true);
    expect(late?.tone).toBe("quiet");
    expect(key(late)).toBe("cloudRepository.stillLinking");
    expect(ids(late)).toEqual([]);
    expect(key(repoRecoveryView(needsGithubNoUrl, { kind: "linking" }, undefined, true))).toBe(
      "cloudRepository.stillLinking",
    );
  });

  test("waiting: says what it waits for, counts down, and can reopen the install page", () => {
    const view = repoRecoveryView(needsGithub, { kind: "waiting", until: 60_000 });
    expect(key(view)).toBe("cloudRepository.waitingGithub");
    expect(view?.until).toBe(60_000);
    expect(ids(view)).toEqual(["reopen"]);
  });

  test("a wait started again on its own has no countdown", () => {
    const view = repoRecoveryView(needsGithub, { kind: "waiting" });
    expect(key(view)).toBe("cloudRepository.waitingGithub");
    expect(view?.until).toBeUndefined();
    expect(ids(view)).toEqual(["reopen"]);
  });

  test("the connect didn't take yet: the quiet wait goes on, with the install page again and no Check again", () => {
    const view = repoRecoveryView(needsGithub, { kind: "notConnected" });
    expect(key(view)).toBe("cloudRepository.waitingGithub");
    expect(view?.tone).toBe("quiet");
    expect(view?.until).toBeUndefined();
    expect(ids(view)).toEqual(["reopen"]);
    expect(ids(repoRecoveryView(needsGithubNoUrl, { kind: "notConnected" }))).toEqual([]);
  });

  test("failure names the repository and offers Try again", () => {
    const view = repoRecoveryView(needsGithub, { kind: "failed" });
    expect(view?.message).toEqual({
      key: "cloudRepository.attachFailedRepo",
      values: { target: { literal: "acme/demo" } },
    });
    expect(ids(view)).toEqual(["retry"]);
  });

  test("failure after a choice retries that choice's name", () => {
    const ambiguous: RepoRecovery = {
      code: "repo.ambiguous",
      choices: [{ fullName: "acme/demo" }, { fullName: "other/demo" }],
      retry: { action: "cloud.repo.add", args: { repo: "demo" } },
    };
    expect(repoRecoveryView(ambiguous, { kind: "failed" }, "other/demo")?.message).toEqual({
      key: "cloudRepository.attachFailedRepo",
      values: { target: { literal: "other/demo" } },
    });
    expect(repoRecoveryView(ambiguous, { kind: "failed" })?.message).toEqual({
      key: "cloudRepository.attachFailedRepo",
      values: { target: { key: "cloudRepository.thisRepository" } },
    });
  });

  test("verified success is a chip naming the connection and the repository", () => {
    expect(repoRecoveryView(needsGithub, { kind: "done", connected: true })).toMatchObject({
      tone: "done",
      message: { key: "cloudRepository.connectedAttached", values: { repo: "acme/demo" } },
      actions: [],
    });
    expect(key(repoRecoveryView(needsGithub, { kind: "done", connected: false }))).toBe("cloudRepository.attachedRepo");
  });

  test("no access keeps install and request access; ambiguous offers each repository", () => {
    // One line naming whose grant leaves the organization out (gap 1), the install button for it.
    expect(
      repoRecoveryView({ code: "repo.no_access", org: "acme", installUrl: needsGithub.installUrl }, { kind: "idle" })
        ?.message,
    ).toEqual({ key: "cloudRepository.grantNotCovered", values: { org: "acme" } });
    expect(
      ids(
        repoRecoveryView({ code: "repo.no_access", org: "acme", installUrl: needsGithub.installUrl }, { kind: "idle" }),
      ),
    ).toEqual(["connect", "requestAccess"]);
    expect(ids(repoRecoveryView({ code: "repo.no_access", org: "acme" }, { kind: "idle" }))).toEqual(["requestAccess"]);
    // With the host's retry (the same add, no GitHub wait): Try again adds it here once access is granted.
    const again = { action: "cloud.repo.add", args: { session: "s", repo: "acme/x" } };
    expect(
      ids(
        repoRecoveryView(
          { code: "repo.no_access", org: "acme", installUrl: needsGithub.installUrl, retry: again },
          { kind: "idle" },
        ),
      ),
    ).toEqual(["connect", "requestAccess", "retry"]);
    expect(ids(repoRecoveryView({ code: "repo.no_access", org: "acme", retry: again }, { kind: "idle" }))).toEqual([
      "requestAccess",
      "retry",
    ]);
    const choices = repoRecoveryView(
      { code: "repo.ambiguous", choices: [{ fullName: "a/x" }, { fullName: "b/x" }] },
      { kind: "idle" },
    );
    expect(choices?.group).toBe(true);
    expect(choices?.actions.map((action) => action.repo)).toEqual(["a/x", "b/x"]);
  });

  test("every phase a person can act in has an action; in-flight calls and the card's own asks have none", () => {
    const phases: RepoRecoveryPhase[] = [{ kind: "idle" }, { kind: "failed" }, { kind: "waiting", until: 1 }];
    for (const recovery of [needsGithub, needsGithubNoUrl])
      for (const phase of phases) {
        const view = repoRecoveryView(recovery, phase);
        // The wait without a link to reopen still says its reason and ETA.
        if (phase.kind === "waiting" && !recovery.installUrl) expect(view?.until).toBe(1);
        else expect(view?.actions.length ?? 0).toBeGreaterThan(0);
      }
    expect(ids(repoRecoveryView(needsGithub, { kind: "retrying" }))).toEqual([]);
    expect(ids(repoRecoveryView(needsGithub, { kind: "linking" }))).toEqual([]);
  });

  test("waitLeft counts down in m:ss and stops at 0:00", () => {
    expect(waitLeft(60_000, 0)).toBe("1:00");
    expect(waitLeft(60_000, 15_500)).toBe("0:45");
    expect(waitLeft(60_000, 90_000)).toBe("0:00");
  });
});
