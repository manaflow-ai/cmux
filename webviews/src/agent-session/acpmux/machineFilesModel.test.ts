import { describe, expect, it } from "vitest";
import { machineFolder } from "./machineFilesModel";

describe("machineFolder", () => {
  it("keeps the daemon's order and tells folders from files", () => {
    const folder = machineFolder({
      path: "/home/me/work/app",
      parent: "/home/me/work",
      entries: [
        { name: "src", path: "/home/me/work/app/src", kind: "dir" },
        { name: "lib", path: "/home/me/work/app/lib", kind: "dir", repo: true },
        { name: "README.md", path: "/home/me/work/app/README.md", kind: "file" },
      ],
    });
    expect(folder.path).toBe("/home/me/work/app");
    expect(folder.parent).toBe("/home/me/work");
    expect(folder.entries.map((entry) => [entry.name, entry.folder, entry.repo])).toEqual([
      ["src", true, false],
      ["lib", true, true],
      ["README.md", false, false],
    ]);
    expect(folder.truncated).toBe(false);
  });

  it("says the root has no parent and keeps the bound", () => {
    const folder = machineFolder({ path: "/", parent: null, entries: [], truncated: true });
    expect(folder.parent).toBeNull();
    expect(folder.truncated).toBe(true);
  });

  it("throws the machine's own sentence", () => {
    expect(() =>
      machineFolder({ error: { code: "list_dir.denied", message: "This machine does not let cmux read that folder" } }),
    ).toThrow("This machine does not let cmux read that folder");
    expect(() => machineFolder(undefined)).toThrow("This machine did not answer");
  });
});
