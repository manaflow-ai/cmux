import { fireEvent, render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { Sidebar } from "../src/components/Sidebar";
import { StatusBar } from "../src/components/StatusBar";
import type { WorkspaceView } from "../src/lib/tree";

const workspace: WorkspaceView = {
  id: 1,
  name: "alpha",
  active: true,
  subtitle: "shell",
  screens: [{
    id: 2,
    workspaceId: 1,
    label: "shell title",
    statusLabel: "named",
    active: true,
    pane: null,
    tab: null,
    panes: [],
    layout: { type: "leaf", pane: 3 },
    activePane: 3,
    zoomedPane: null,
    unread: false,
  }],
};

describe("TUI chrome components", () => {
  it("renders the built-in sidebar rail and keeps new workspace directly in the workspace list", () => {
    const onNewWorkspace = vi.fn();
    const { container, getByRole } = render(
      <Sidebar
        open
        workspaces={[workspace]}
        onClose={vi.fn()}
        onSelect={vi.fn()}
        onNewWorkspace={onNewWorkspace}
        onNewScreen={vi.fn()}
        onCloseWorkspace={vi.fn()}
        onRenameWorkspace={vi.fn()}
      />,
    );

    expect(container.querySelector(".workspace-row.active .workspace-rail")).toHaveTextContent("▎");
    const newWorkspace = getByRole("button", { name: "+ new workspace" });
    expect(newWorkspace.parentElement).toHaveClass("workspace-list");
    fireEvent.click(newWorkspace);
    expect(onNewWorkspace).toHaveBeenCalledOnce();
  });

  it("uses the screen display name and omits the web-only client count from the TUI status row", () => {
    const { container, getByRole } = render(
      <StatusBar
        workspace={workspace}
        session="dogv7"
        onSelectScreen={vi.fn()}
        onNewScreen={vi.fn()}
        onCloseScreen={vi.fn()}
        onRenameScreen={vi.fn()}
      />,
    );

    expect(getByRole("button", { name: "named" })).toHaveClass("active");
    expect(container.querySelector(".session-badge")).toHaveTextContent("[dogv7]");
    expect(container.querySelector(".clients-indicator")).toBeNull();
  });
});
