// Nightly builds and Actions runs in prose (Leo 2026-11-10, of "build 4270949510401," as plain
// text in a coordinator's reply: "should these be linked too?"). A nightly build number is its
// run's id followed by the attempt as two digits (nightly.yml, "Fix this run's build number").
import { expect, test } from "bun:test";
import { runReferences } from "./githubReferences";

const hrefs = (text: string, repository?: string) => runReferences(text, repository).map((run) => run.href);

test("a nightly build links to its run, whatever the chat's repository", () => {
  const [build] = runReferences(
    "Leo's flow passes on build 4270949510401, the nightly.",
    "teamleaderleo/leo-workspace",
  );
  expect(build).toMatchObject({
    text: "4270949510401",
    source: "build",
    run: 42709495104,
    attempt: 1,
    href: "https://github.com/manaflow-ai/cmux/actions/runs/42709495104",
  });
  expect("Leo's flow passes on build 4270949510401, the nightly.".slice(build!.start, build!.end)).toBe(
    "4270949510401",
  );
});

test("every way a build is named; a later attempt links to that attempt", () => {
  expect(
    hrefs(
      "nightly 4270949510401, nightly build 4270949510403, nightly-next build #4270949510402 and Build 4270949510401.",
    ),
  ).toEqual([
    "https://github.com/manaflow-ai/cmux/actions/runs/42709495104",
    "https://github.com/manaflow-ai/cmux/actions/runs/42709495104/attempts/3",
    "https://github.com/manaflow-ai/cmux/actions/runs/42709495104/attempts/2",
    "https://github.com/manaflow-ai/cmux/actions/runs/42709495104",
  ]);
});

test("a run links in the chat's repository, and needs one", () => {
  expect(hrefs("run 42709495104 failed; rerun 42709495104, run id: 42709495104, Run ID 42709495104", "o/r")).toEqual([
    "https://github.com/o/r/actions/runs/42709495104",
    "https://github.com/o/r/actions/runs/42709495104",
    "https://github.com/o/r/actions/runs/42709495104",
    "https://github.com/o/r/actions/runs/42709495104",
  ]);
  expect(hrefs("run 42709495104 failed")).toEqual([]);
});

test("look-alikes stay text", () => {
  expect(
    hrefs(
      [
        "4270949510401 alone",
        "build 2026",
        "build 1.2.3",
        "build 12345678901.5",
        "the 2026 build",
        "run 3 tests",
        "call 555-123-4567 or +1 415 555 0100",
        "build 4270949510400",
        "build 427094951",
        "prebuild 4270949510401",
        "run 427094951040155",
        "run 42709495104-1",
        "run 42709495104abc",
        "rebuilds 4270949510401",
        "/build/4270949510401",
      ].join("; "),
      "o/r",
    ),
  ).toEqual([]);
});
