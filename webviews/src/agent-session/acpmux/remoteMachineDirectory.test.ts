import { expect, test } from "bun:test";
import { machineDirectory, machineDirectoryHost, type MachineListing } from "./remoteMachineDirectory";

const listing = (path: string, extra: Partial<MachineListing> = {}): MachineListing => ({
  path,
  parent: "/",
  home: "/home/dev",
  entries: [
    { name: "api", path: `${path}/api`, kind: "dir", repo: true },
    { name: "notes.txt", path: `${path}/notes.txt`, kind: "file" },
  ],
  ...extra,
});

test("keeps only folders, in the daemon's order", () => {
  expect(machineDirectory(listing("/home/dev")).directories).toEqual(["/home/dev/api"]);
});

test("a refusal or silence is an error the chooser shows", () => {
  expect(() => machineDirectory(undefined)).toThrow("did not answer");
  expect(() => machineDirectory({ error: { code: "denied", message: "No access" } })).toThrow("No access");
});

test("starts where the machine says, then maps ~ to its home", async () => {
  const asked: unknown[] = [];
  const host = machineDirectoryHost(async (method, params) => {
    expect(method).toBe("machine.folder.list");
    asked.push(params);
    return listing(typeof params.path === "string" ? params.path : "/home/dev");
  });
  expect((await host.list(""))?.path).toBe("/home/dev");
  await host.list("~");
  await host.list("~/api");
  await host.list("/srv");
  expect(asked).toEqual([{}, { path: "/home/dev" }, { path: "/home/dev/api" }, { path: "/srv" }]);
});

test("names the picked machine on every listing so the host addresses it", async () => {
  const asked: unknown[] = [];
  const host = machineDirectoryHost(async (_method, params) => {
    asked.push(params);
    return listing("/home/dev");
  }, "lab-box");
  await host.list("");
  await host.list("/srv");
  expect(asked).toEqual([{ machine: "lab-box" }, { path: "/srv", machine: "lab-box" }]);
});
