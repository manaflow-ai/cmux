import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, useLayoutEffect } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { agentHomeTrust, type TrustSource } from "../folderTrust";
import { useFolderTrustAsk } from "../useFolderTrustAsk";

// Leo 2026-11-03: "why does it even take time to read settings? you know what things are. the read
// defaults/the "not working in a project" thing that should all be instant". A chat in no project runs
// in its workspace's agent-home folder, which acpmux trusts by construction (trust.rs `made_by_cmux`).
// The pane drew no answer until `acp.trust.get` had read the agents' settings files (up to 1.5 s); it
// now draws trusted on the first frame, and the read only refreshes it.

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "localStorage", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterEach(() => {
  act(() => root?.unmount());
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
});

const HOME = "/Users/me/Library/Application Support/cmux/agent-home/ws_0123456789abcdef";

/// The trust state each committed frame draws for a chat in `cwd`, while the folder's read never answers
/// (a render React throws away for a state set during render is no frame: recorded at layout).
async function firstFrames(cwd: string, local = true) {
  const frames: { trusted: boolean; blocked: unknown; ask: unknown }[] = [];
  let reads = 0;
  const source: TrustSource = {
    get: () => {
      reads += 1;
      return new Promise(() => {});
    },
    set: async () => ({}),
  };
  function Probe() {
    const trust = useFolderTrustAsk(
      source,
      { cwd, family: "claude", prompts: 0, authority: "local", visit: "visit-1" },
      true,
      local,
    );
    useLayoutEffect(() => {
      frames.push({ trusted: trust.trusted, blocked: trust.blocked, ask: trust.ask });
    });
    return null;
  }
  await act(async () => root!.render(<Probe />));
  return { frames, reads };
}

test("a no-project chat's agent-home folder is trusted from its first frame, with the read still made", async () => {
  const { frames, reads } = await firstFrames(HOME);
  expect(frames.length).toBeGreaterThan(0);
  for (const frame of frames) {
    expect(frame.trusted).toBe(true);
    expect(frame.blocked).toBeUndefined();
    expect(frame.ask).toBeUndefined();
  }
  expect(reads).toBe(1);
});

test("any other unread folder still waits on its read", async () => {
  const { frames } = await firstFrames("/work/never-read");
  expect(frames.at(-1)?.trusted).toBe(false);
  expect(frames.at(-1)?.blocked).toEqual({});
});

test("only the folder the app made counts, on this computer", async () => {
  expect(agentHomeTrust(HOME)).toEqual({ cwd: HOME, level: "trusted", decided: true });
  expect(agentHomeTrust(`${HOME}/`)).toBeDefined();
  // A folder inside it, the root itself, or a look-alike elsewhere is read as any folder (trust.rs).
  expect(agentHomeTrust(`${HOME}/src`)).toBeUndefined();
  expect(agentHomeTrust("/Users/me/Library/Application Support/cmux/agent-home")).toBeUndefined();
  expect(agentHomeTrust("/Users/me/Library/Application Support/cmux/agent-home-x/ws")).toBeUndefined();
  const remote = await firstFrames(HOME, false);
  expect(remote.frames.at(-1)?.trusted).toBe(false);
});
