import { act, fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { MachineFiles } from "./MachineFiles";

const listing = (path: string, parent: string | null, entries: { name: string; kind: string }[]) => ({
  path,
  parent,
  entries: entries.map((entry) => ({ ...entry, path: `${path === "/" ? "" : path}/${entry.name}` })),
});

describe("MachineFiles", () => {
  it("starts at the chat's folder, goes into a folder and opens a file", async () => {
    const list = vi.fn(async (path: string | undefined) =>
      path === "/w/app/src"
        ? listing("/w/app/src", "/w/app", [{ name: "main.ts", kind: "file" }])
        : listing("/w/app", "/w", [
            { name: "src", kind: "dir" },
            { name: "README.md", kind: "file" },
          ]),
    );
    const onOpenFile = vi.fn();
    render(<MachineFiles list={list} start="/w/app" onOpenFile={onOpenFile} onClose={() => {}} />);
    expect(list).toHaveBeenCalledWith("/w/app");
    fireEvent.mouseDown(await screen.findByText("src/"));
    fireEvent.mouseDown(await screen.findByText("main.ts"));
    expect(list).toHaveBeenLastCalledWith("/w/app/src");
    expect(onOpenFile).toHaveBeenCalledWith("/w/app/src/main.ts");
  });

  it("goes up to the parent and shows the machine's refusal with Try again", async () => {
    let refuse = true;
    const list = vi.fn(async (path: string | undefined) => {
      if (path === "/w") {
        if (refuse)
          return { error: { code: "list_dir.denied", message: "This machine does not let cmux read that folder" } };
        return listing("/w", "/", [{ name: "app", kind: "dir" }]);
      }
      return listing("/w/app", "/w", []);
    });
    const { container } = render(<MachineFiles list={list} onOpenFile={() => {}} onClose={() => {}} />);
    expect(list).toHaveBeenCalledWith(undefined);
    await screen.findByText("/w/app");
    fireEvent.click(container.querySelector(".acpmux-machine-files-up")!);
    expect(await screen.findByText(/does not let cmux read/)).toBeTruthy();
    refuse = false;
    await act(async () => fireEvent.click(container.querySelector(".acpmux-machine-files-retry")!));
    expect(await screen.findByText("app/")).toBeTruthy();
  });

  it("closes on Escape", async () => {
    const onClose = vi.fn();
    const { container } = render(
      <MachineFiles list={async () => listing("/", null, [])} onOpenFile={() => {}} onClose={onClose} />,
    );
    fireEvent.keyDown(container.querySelector("dialog")!, { key: "Escape" });
    expect(onClose).toHaveBeenCalled();
  });
});
