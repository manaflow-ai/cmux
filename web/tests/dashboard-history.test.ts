import { describe, expect, test } from "bun:test";
import { createDashboardHistory } from "../dashboard-app/lib/history";

type State = Record<string, unknown> | null;

/**
 * A window whose history behaves like the Next app router's patch: an
 * external write is mirrored into Next state and then echoed back with an
 * `__NA` state object, which is what Next's `useInsertionEffect` does.
 */
function fakeWindow() {
  const location = { pathname: "/dashboard", search: "", hash: "" };
  let state: State = null;
  const setUrl = (url?: string | URL | null) => {
    if (!url) return;
    const parsed = new URL(String(url), "http://localhost");
    location.pathname = parsed.pathname;
    location.search = parsed.search;
    location.hash = parsed.hash;
  };
  const echoes: string[] = [];
  const history = {
    get state() {
      return state;
    },
    pushState(data: State, _unused: string, url?: string | URL | null) {
      state = data;
      setUrl(url);
      if (!data?.__NA) echoes.push(String(url));
    },
    replaceState(data: State, _unused: string, url?: string | URL | null) {
      state = data;
      setUrl(url);
    },
    go() {},
    back() {},
    forward() {},
    length: 1,
  };
  const win = {
    location,
    history,
    document: { baseURI: "http://localhost/", title: "" },
    addEventListener() {},
    removeEventListener() {},
    setTimeout,
    clearTimeout,
  };
  return { win: win as unknown as Window, echoes };
}

describe("dashboard history inside the Next app router", () => {
  test("Next's __NA echo does not notify router subscribers", () => {
    const { win } = fakeWindow();
    const history = createDashboardHistory(win);
    const notified: string[] = [];
    const unsubscribe = history.subscribe(({ action }) => notified.push(action.type));

    win.history.replaceState({ __NA: true, __PRIVATE_NEXTJS_INTERNALS_TREE: {} }, "", "/dashboard");
    expect(notified).toEqual([]);

    unsubscribe();
    history.destroy();
  });

  test("an external write still reaches the router", () => {
    const { win } = fakeWindow();
    const history = createDashboardHistory(win);
    const notified: string[] = [];
    const unsubscribe = history.subscribe(({ action }) => notified.push(action.type));

    win.history.pushState({ other: true }, "", "/dashboard/teams");
    expect(notified).toEqual(["PUSH"]);
    expect(history.location.pathname).toBe("/dashboard/teams");

    unsubscribe();
    history.destroy();
  });

  test("destroy restores the functions that were patched before the router", () => {
    const { win } = fakeWindow();
    const nextPush = win.history.pushState;
    const nextReplace = win.history.replaceState;
    const history = createDashboardHistory(win);
    expect(win.history.pushState).not.toBe(nextPush);
    history.destroy();
    expect(win.history.pushState).toBe(nextPush);
    expect(win.history.replaceState).toBe(nextReplace);
  });
});
