// hq#2834: a live frame whose owner stamps no author takes its run's author only when one running
// run has that id. Run ids are unique per author only (a Cloud brain counts `run_<n>` per Chief), so
// two Chiefs running `run_1` in one conversation must not have one's text shown under the other.
import { expect, test } from "bun:test";
import { RunBook } from "../src/pages/home-channels/runs";
import type { HomeRun } from "../src/pages/home-channels/types";

const now = Date.now();
const run = (author: string, id = "run_1", status: HomeRun["status"] = "running"): HomeRun => ({
  id,
  conversation: "c",
  author,
  status,
  startedAt: now,
  updatedAt: now,
  rev: 1,
  stepCount: 0,
  answers: [],
});

test("one running run with the id gives its author", () => {
  const book = new RunBook();
  book.setRuns([run("chief-a"), run("chief-b", "run_2")]);
  expect(book.soleRunningAuthor("c", "run_1", now)).toBe("chief-a");
  expect(book.soleRunningAuthor("c", "run_2", now)).toBe("chief-b");
});

test("two Chiefs running the same run id give no author", () => {
  const book = new RunBook();
  book.setRuns([run("chief-a"), run("chief-b")]);
  expect(book.soleRunningAuthor("c", "run_1", now)).toBeUndefined();
});

test("a finished run with the same id does not make it ambiguous", () => {
  const book = new RunBook();
  book.setRuns([run("chief-a"), run("chief-b", "run_1", "done")]);
  expect(book.soleRunningAuthor("c", "run_1", now)).toBe("chief-a");
});

test("no running run with the id gives no author", () => {
  const book = new RunBook();
  book.setRuns([run("chief-a", "run_1", "done")]);
  expect(book.soleRunningAuthor("c", "run_1", now)).toBeUndefined();
  expect(book.soleRunningAuthor("other", "run_1", now)).toBeUndefined();
});
