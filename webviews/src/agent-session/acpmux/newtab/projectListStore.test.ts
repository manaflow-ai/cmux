import { afterEach, beforeEach, expect, test } from "bun:test";
import { storedProjectList, storeProjectList } from "./projectListStore";

// A New Tab page drew its folder menu from its chats' folders until the host's `project.list` answered:
// a clone of GitHub's cmux-workspace in ~/cmux read "cmux", and folders only the project list holds were
// gone. The page keeps the last answer for the next page's first frame.

const scope = globalThis as { localStorage?: Storage };
let saved: { had: boolean; value: Storage | undefined } = { had: false, value: undefined };

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length() {
      return values.size;
    },
    clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null,
    key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => void values.delete(key),
    setItem: (key, value) => void values.set(key, String(value)),
  };
}

beforeEach(() => {
  saved = { had: "localStorage" in scope, value: scope.localStorage };
  scope.localStorage = memoryStorage();
});

afterEach(() => {
  if (saved.had) scope.localStorage = saved.value;
  else delete scope.localStorage;
});

const repo = { root: "/Users/me/cmux", name: "cmux-workspace", github: "me/cmux-workspace" };

test("the next page reads the folders and repositories the last answer listed", () => {
  storeProjectList({ projects: ["/Users/me/cmux", "/Users/me/site"], repos: { "/Users/me/cmux": repo } });
  expect(storedProjectList()).toEqual({
    projects: ["/Users/me/cmux", "/Users/me/site"],
    repos: { "/Users/me/cmux": repo },
  });
});

test("an empty answer keeps the list it had: a page the host has not wired answers none", () => {
  storeProjectList({ projects: ["/Users/me/cmux"], repos: {} });
  storeProjectList({ projects: [] });
  storeProjectList(undefined);
  expect(storedProjectList()?.projects).toEqual(["/Users/me/cmux"]);
});

test("only the listed folders' repositories are kept, and nothing malformed is read back", () => {
  storeProjectList({ projects: ["/Users/me/cmux", 7, ""], repos: { "/Users/me/cmux": repo, "/gone": repo } });
  expect(storedProjectList()).toEqual({ projects: ["/Users/me/cmux"], repos: { "/Users/me/cmux": repo } });
  scope.localStorage!.setItem("cmux.acpmux.newTab.projects.v1", "{not json");
  expect(storedProjectList()).toBeUndefined();
  scope.localStorage!.setItem("cmux.acpmux.newTab.projects.v1", JSON.stringify({ projects: "x" }));
  expect(storedProjectList()).toBeUndefined();
});

test("a blocked store keeps nothing and reads nothing", () => {
  scope.localStorage = undefined;
  storeProjectList({ projects: ["/Users/me/cmux"] });
  expect(storedProjectList()).toBeUndefined();
});
