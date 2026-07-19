import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ClientsIndicator } from "../src/components/ClientsIndicator";
import type { ClientInfo } from "cmux/browser";

const clients: ClientInfo[] = [
  {
    client: 1,
    transport: "ws",
    name: "Laptop",
    kind: "web",
    connected_seconds: 10,
    attached: [7],
    sizes: [{ surface: 7, cols: 126, rows: 38 }],
    self: true,
    size_participating: true,
  },
  {
    client: 2,
    transport: "unix",
    name: null,
    kind: "tui",
    connected_seconds: 4,
    attached: [],
    sizes: [],
    self: false,
    size_participating: true,
  },
];

describe("ClientsIndicator", () => {
  it("refreshes on open and renders presence details plus non-self disconnect", () => {
    const onRefresh = vi.fn();
    const onDetach = vi.fn();
    render(<ClientsIndicator clients={clients} onRefresh={onRefresh} onDetach={onDetach} />);

    fireEvent.click(screen.getByRole("button", { name: "2 clients" }));
    expect(onRefresh).toHaveBeenCalledOnce();
    expect(screen.getByText("Laptop")).toBeInTheDocument();
    expect(screen.getByText("this device")).toBeInTheDocument();
    expect(screen.getByText("126x38")).toBeInTheDocument();
    expect(screen.getByText("unnamed")).toBeInTheDocument();
    expect(screen.getAllByRole("menuitem")).toHaveLength(1);

    fireEvent.click(screen.getByRole("menuitem", { name: "Disconnect" }));
    expect(onDetach).toHaveBeenCalledWith(2);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("dismisses with Escape", () => {
    render(<ClientsIndicator clients={clients} onRefresh={vi.fn()} onDetach={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: "2 clients" }));
    fireEvent.keyDown(document, { key: "Escape" });
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });
});
