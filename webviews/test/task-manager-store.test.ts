// The Task Manager page's store and model (webviews/src/pages/task-manager): a header click sorts
// (again flips it, equal rows keep the app's order, no CPU sorts as zero), one row is selected and
// the app hears it, a new sample replaces the rows and keeps the selection only while its process
// is listed (or follows the app's one selection, shared by every page), and Kill Process calls the
// app only from a real gesture on a row the policy allows.
import { expect, test } from "bun:test";
import { killableRow, nextOrder, pidText, sortRows, steppedSelection } from "../src/pages/task-manager/model";
import {
  firstSampleSnapshot,
  manyRowsSnapshot,
  MockTaskManagerProvider,
  normalSnapshot,
} from "../src/pages/task-manager/mockProvider";
import { TaskManagerStore } from "../src/pages/task-manager/store";
import { TaskManagerOps, type TaskManagerSnapshot } from "../src/pages/task-manager/types";

const ids = (rows: { id: string }[]) => rows.map((row) => row.id);

test("a header click sorts ascending, the same header flips it, another starts ascending", () => {
  const first = nextOrder(null, "memory");
  expect(first).toEqual({ key: "memory", ascending: true });
  expect(nextOrder(first, "memory")).toEqual({ key: "memory", ascending: false });
  expect(nextOrder({ key: "memory", ascending: false }, "pid")).toEqual({ key: "pid", ascending: true });
});

test("each column sorts by its value; no order keeps the app's", () => {
  const rows = normalSnapshot().rows;
  expect(ids(sortRows(rows, null))).toEqual(ids(rows));
  const byMemory = sortRows(rows, { key: "memory", ascending: false });
  expect(byMemory[0].name).toBe("cmux");
  expect(byMemory.at(-1)?.name).toBe("zsh");
  const byPid = sortRows(rows, { key: "pid", ascending: true }).map((row) => row.pid);
  expect(byPid).toEqual([...byPid].sort((a, b) => a - b));
  const byName = sortRows(rows, { key: "name", ascending: true }).map((row) => row.name);
  expect(byName[0]).toBe("bun");
  const byCpu = sortRows(rows, { key: "cpu", ascending: false });
  expect(byCpu[0].name).toBe("bun");
});

test("a sort is stable, and a row with no CPU yet sorts as zero", () => {
  const rows = firstSampleSnapshot().rows;
  // Every CPU is null: the app's order stands either way.
  expect(ids(sortRows(rows, { key: "cpu", ascending: true }))).toEqual(ids(rows));
  expect(ids(sortRows(rows, { key: "cpu", ascending: false }))).toEqual(ids(rows));
  const mixed = [{ ...rows[0], cpu: 0.5 }, ...rows.slice(1)];
  expect(sortRows(mixed, { key: "cpu", ascending: false })[0].id).toBe(rows[0].id);
  expect(sortRows(mixed, { key: "cpu", ascending: true }).at(-1)?.id).toBe(rows[0].id);
});

test("equal pids on two machines tie: either direction keeps the app's order", () => {
  const base = normalSnapshot().rows[0];
  const rows = [
    { ...base, id: "local:4242", host: "local", pid: 4242 },
    { ...base, id: "a-remote:4242", host: "a-remote", pid: 4242 },
  ];
  expect(ids(sortRows(rows, { key: "pid", ascending: true }))).toEqual(["local:4242", "a-remote:4242"]);
  expect(ids(sortRows(rows, { key: "pid", ascending: false }))).toEqual(["local:4242", "a-remote:4242"]);
});

test("the PID column shows a pid on this Mac and host:pid on another", () => {
  const rows = manyRowsSnapshot().rows;
  expect(pidText(rows[0])).toBe("501");
  expect(pidText(rows.find((row) => row.host !== "local")!)).toBe("m-cloud:4242");
});

test("arrow keys step the selection through the shown rows and stop at the ends", () => {
  const rows = normalSnapshot().rows;
  expect(steppedSelection(rows, null, 1)).toBe(rows[0].id);
  expect(steppedSelection(rows, null, -1)).toBe(rows.at(-1)!.id);
  expect(steppedSelection(rows, rows[0].id, -1)).toBe(rows[0].id);
  expect(steppedSelection(rows, rows[0].id, 1)).toBe(rows[1].id);
  expect(steppedSelection([], null, 1)).toBeNull();
});

test("selecting a row tells the app; selecting it again or an unlisted row does not", async () => {
  const host = new MockTaskManagerProvider();
  const store = new TaskManagerStore(host);
  await store.start();
  store.select("local:734");
  store.select("local:734");
  store.select("local:99999");
  expect(store.getState().selected).toBeNull();
  expect(host.calls).toEqual([
    { op: TaskManagerOps.select, params: { ids: ["local:734"] } },
    { op: TaskManagerOps.select, params: { ids: [] } },
  ]);
});

test("a new sample replaces the rows in the chosen order; the selection stays while listed", () => {
  const host = new MockTaskManagerProvider();
  const store = new TaskManagerStore(host, { snapshot: normalSnapshot() });
  store.sortBy("memory");
  store.select("local:734");
  const before = store.getState();
  const next: TaskManagerSnapshot = {
    ...normalSnapshot(),
    revision: 13,
    rows: normalSnapshot().rows.map((row) => (row.id === "local:733" ? { ...row, memoryBytes: 1e12 } : row)),
  };
  store.replace(next);
  const after = store.getState();
  expect(after).not.toBe(before);
  expect(after.snapshot.revision).toBe(13);
  expect(after.rows.at(-1)?.id).toBe("local:733");
  expect(after.selected).toBe("local:734");
  host.calls.length = 0;
  store.replace({ ...next, revision: 14, rows: next.rows.filter((row) => row.id !== "local:734") });
  expect(store.getState().selected).toBeNull();
  expect(host.calls).toEqual([{ op: TaskManagerOps.select, params: { ids: [] } }]);
});

test("the stream's first event fills the page", async () => {
  const store = new TaskManagerStore(new MockTaskManagerProvider(manyRowsSnapshot()));
  expect(store.getState().rows).toEqual([]);
  await store.start();
  expect(store.getState().snapshot.revision).toBe(340);
  expect(store.getState().rows.length).toBe(manyRowsSnapshot().rows.length);
});

test("Kill Process calls the app only from a real gesture, on a selected row the policy allows", () => {
  const host = new MockTaskManagerProvider();
  const store = new TaskManagerStore(host, { snapshot: normalSnapshot() });
  expect(store.kill({ isTrusted: true })).toBe(false); // nothing selected
  store.select("local:734");
  host.calls.length = 0;
  expect(store.kill({ isTrusted: false })).toBe(false); // page script, not the person
  expect(host.calls).toEqual([]);
  expect(store.kill({ isTrusted: true })).toBe(true);
  expect(host.calls).toEqual([{ op: TaskManagerOps.kill, params: { id: "local:734" } }]);
  // The app itself: the policy's refusal turns Kill Process off.
  store.select("local:501");
  host.calls.length = 0;
  expect(killableRow(store.getState().snapshot.rows, "local:501")).toBeNull();
  expect(store.kill({ isTrusted: true })).toBe(false);
  expect(host.calls).toEqual([]);
});

test("without a host the page says so and kills nothing", () => {
  const store = new TaskManagerStore(null, { snapshot: normalSnapshot(), selected: "local:734" });
  expect(store.getState().unavailable).toBe(true);
  expect(store.kill({ isTrusted: true })).toBe(false);
});

test("two pages share the app's one selection: a click on a row already shown still moves the app", async () => {
  const host = new MockTaskManagerProvider(normalSnapshot(), { sharedSelection: true });
  const first = new TaskManagerStore(host);
  const second = new TaskManagerStore(host);
  await first.start();
  await second.start();
  first.select("local:733");
  await Promise.resolve();
  second.select("local:734");
  await Promise.resolve();
  expect(host.selected).toBe("local:734");
  expect(first.getState().selected).toBe("local:734");
  host.calls.length = 0;
  first.select("local:733");
  await Promise.resolve();
  expect(host.calls).toEqual([{ op: TaskManagerOps.select, params: { ids: ["local:733"] } }]);
  expect(host.selected).toBe("local:733");
  expect(first.getState().selected).toBe("local:733");
  expect(second.getState().selected).toBe("local:733");
  // Kill Process acts on what both pages show.
  host.calls.length = 0;
  expect(second.kill({ isTrusted: true })).toBe(true);
  expect(host.calls).toEqual([{ op: TaskManagerOps.kill, params: { id: "local:733" } }]);
});

test("a selection broadcast updates a page that did not click; a click that differs from it is sent", () => {
  const host = new MockTaskManagerProvider();
  const store = new TaskManagerStore(host, { snapshot: normalSnapshot() });
  store.select("local:733");
  // The app broadcasts another window's selection: this page follows it without telling the app.
  host.calls.length = 0;
  store.replace({ ...normalSnapshot(), selected: "local:734" });
  expect(store.getState().selected).toBe("local:734");
  expect(host.calls).toEqual([]);
  // Clicking the row that page showed before now differs from the app's: it is sent.
  store.select("local:733");
  expect(host.calls).toEqual([{ op: TaskManagerOps.select, params: { ids: ["local:733"] } }]);
  // A broadcast of none clears it; an unlisted id selects nothing.
  store.replace({ ...normalSnapshot(), selected: null });
  expect(store.getState().selected).toBeNull();
  store.replace({ ...normalSnapshot(), selected: "local:99999" });
  expect(store.getState().selected).toBeNull();
});
