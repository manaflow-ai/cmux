import { expect, test } from "bun:test";
import type { PageClient } from "../src/pages/shared/pageClient";
import { ChiefWorkStore } from "../src/pages/home-channels/ChiefWorkStore";
import { DaemonHomeClient } from "../src/pages/home-channels/daemonHome";
import { HomeOps } from "../src/pages/home-channels/types";
import type { HomeChiefWork } from "../src/pages/home-channels/chiefWorkTypes";
import { MockHomeProvider } from "../src/pages/home-channels/mockProvider";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

const work = (name: string): HomeChiefWork => ({
  agents: [{ id: name, name, state: "working", task: "Build the preview" }],
  tasks: [{ id: `${name}/server`, sessionId: name, title: "Preview server", status: "running" }],
  truncated: false,
  taskSources: ["harness"],
});

test("the real Home gallery answers participant picture reads without an unhandled rejection", async () => {
  const provider = new MockHomeProvider();
  expect(await provider.call<{ avatar: null }>(HomeOps.avatar, { participant: "agent_mux" })).toEqual({ avatar: null });
});

function owner() {
  const requests: { chief: string; answer: ReturnType<typeof deferred<HomeChiefWork>> }[] = [];
  const client = {
    call(op: string, params: { chief: string }) {
      expect(op).toBe(HomeOps.chiefWork);
      const answer = deferred<HomeChiefWork>();
      requests.push({ chief: params.chief, answer });
      return answer.promise;
    },
  } as unknown as PageClient;
  return { requests, book: new ChiefWorkStore(client) };
}

test("opening a Chief reads once, deduplicates refresh and never shows another Chief's late reply", async () => {
  const { book, requests } = owner();
  book.select("chief-a");
  await book.refresh();
  expect(requests).toHaveLength(1);
  book.select("chief-b");
  expect(requests.map((r) => r.chief)).toEqual(["chief-a", "chief-b"]);
  requests[1]!.answer.resolve(work("agent-b"));
  await requests[1]!.answer.promise;
  expect(book.getSnapshot().snapshot?.agents[0]?.id).toBe("agent-b");
  requests[0]!.answer.resolve(work("agent-a"));
  await requests[0]!.answer.promise;
  expect(book.getSnapshot().snapshot?.agents[0]?.id).toBe("agent-b");
});

test("a failed inventory is unavailable, keeps the last snapshot on refresh, and can retry", async () => {
  const { book, requests } = owner();
  book.select("chief");
  requests[0]!.answer.reject(new Error("owner offline"));
  await requests[0]!.answer.promise.catch(() => {});
  expect(book.getSnapshot()).toMatchObject({ chief: "chief", failed: true, loading: false });
  expect(book.getSnapshot().snapshot).toBeUndefined();
  const retry = book.refresh();
  requests[1]!.answer.resolve(work("agent"));
  await retry;
  const refresh = book.refresh();
  requests[2]!.answer.reject(new Error("owner offline"));
  await refresh;
  expect(book.getSnapshot()).toMatchObject({ failed: true, loading: false, snapshot: work("agent") });
});

test("closing a panel invalidates an unfinished read and a new opening reads again", async () => {
  const { book, requests } = owner();
  book.select("chief");
  book.select(undefined);
  requests[0]!.answer.resolve(work("old-agent"));
  await requests[0]!.answer.promise;
  expect(book.getSnapshot()).toEqual({ chief: undefined, loading: false, failed: false });
  book.select("chief");
  expect(requests).toHaveLength(2);
  expect(book.getSnapshot().snapshot).toBeUndefined();
});

test("the adapter sends a scoped read to the local conversation owner, never the cloud transport", async () => {
  const calls: { cmd: string; params?: unknown }[] = [];
  const local = {
    request(cmd: string, params?: unknown) {
      calls.push({ cmd, params });
      if (cmd === "identify") return Promise.resolve({ capabilities: ["chief-work-v1"] });
      if (cmd === "chief-work") return Promise.resolve(work("owned-agent"));
      throw new Error(`unexpected local command: ${cmd}`);
    },
  };
  const cloud = {
    request() {
      throw new Error("must not read this machine's inventory");
    },
  };
  const home = new DaemonHomeClient(cloud as never, local as never);
  expect(await home.call<HomeChiefWork>(HomeOps.chiefWork, { chief: "chief-2" })).toEqual(work("owned-agent"));
  expect(calls).toEqual([
    { cmd: "identify", params: undefined },
    { cmd: "chief-work", params: { chief: "chief-2" } },
  ]);
});

test("an older owner cannot be mistaken for an empty task inventory", async () => {
  const local = {
    request(cmd: string) {
      expect(cmd).toBe("identify");
      return Promise.resolve({ capabilities: [] });
    },
  };
  const home = new DaemonHomeClient(local as never);
  await expect(home.call(HomeOps.chiefWork, { chief: "chief" })).rejects.toMatchObject({
    code: "cmux.page.unavailable",
  });
});
