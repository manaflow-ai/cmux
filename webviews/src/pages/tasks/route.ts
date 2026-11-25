// The page's route (`#/<scope>?new=<n>`), which the host sets for Open Tasks (`#/all`), My Tasks
// (`#/mine`) and New Task (`#/?new=<n>`, `new` changes and the scope stays): client view state, set
// only by a user run.
import type { Layout, Scope } from "./types";

export interface TasksRoute {
  scope?: Scope;
  /** Changes on every New Task request. */
  newTask?: string;
}

export function parseRoute(hash: string): TasksRoute {
  const text = hash.replace(/^#\/?/, "");
  const [path = "", query = ""] = text.split("?");
  const route: TasksRoute = {};
  if (path === "all" || path === "mine") route.scope = path;
  const newTask = new URLSearchParams(query).get("new");
  if (newTask) route.newTask = newTask;
  return route;
}

/** The layout setting the host sets on `<html data-tasks-layout>`; inbox when unset (decision T2). */
export function parseLayout(value: string | undefined): Layout {
  return value === "list" || value === "board" || value === "inbox" ? value : "inbox";
}
