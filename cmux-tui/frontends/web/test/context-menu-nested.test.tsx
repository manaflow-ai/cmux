import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ContextMenu } from "../src/components/ContextMenu";

describe("nested ContextMenu", () => {
  it("opens a reusable submenu with mouse or ArrowRight and runs its action", () => {
    const onClose = vi.fn();
    const onSelect = vi.fn();
    render(
      <ContextMenu
        point={{ x: 20, y: 20 }}
        onClose={onClose}
        items={[{
          label: "Clients",
          children: [{ label: "Use all client sizes", onSelect }],
        }]}
      />,
    );

    const parent = screen.getByRole("menuitem", { name: "Clients" });
    const child = screen.getByRole("menuitem", { name: "Use all client sizes", hidden: true });
    parent.focus();
    fireEvent.keyDown(parent, { key: "ArrowRight" });
    expect(child).toHaveFocus();

    fireEvent.click(child);
    expect(onSelect).toHaveBeenCalledOnce();
    expect(onClose).toHaveBeenCalledOnce();
  });
});
