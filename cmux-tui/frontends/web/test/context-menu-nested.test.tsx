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

  it("keeps a bottom-right submenu inside the viewport", () => {
    const originalWidth = window.innerWidth;
    const originalHeight = window.innerHeight;
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 800 });
    Object.defineProperty(window, "innerHeight", { configurable: true, value: 600 });
    const rect = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
      if (this.classList.contains("context-menu-submenu")) {
        return DOMRect.fromRect({ x: 778, y: 570, width: 190, height: 120 });
      }
      if (this.classList.contains("context-menu-entry")) {
        return DOMRect.fromRect({ x: 590, y: 570, width: 190, height: 36 });
      }
      return DOMRect.fromRect({ x: 590, y: 500, width: 190, height: 80 });
    });

    render(
      <ContextMenu
        point={{ x: 780, y: 580 }}
        onClose={vi.fn()}
        items={[{ label: "Clients", children: [{ label: "Use all client sizes" }] }]}
      />,
    );

    const submenu = screen.getAllByRole("menu", { hidden: true })[1];
    expect(submenu).toHaveStyle({ left: "402px", top: "472px" });

    rect.mockRestore();
    Object.defineProperty(window, "innerWidth", { configurable: true, value: originalWidth });
    Object.defineProperty(window, "innerHeight", { configurable: true, value: originalHeight });
  });

  it("scrolls keyboard-focused rows into a constrained menu viewport", () => {
    const original = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "scrollIntoView");
    const scrollIntoView = vi.fn();
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: scrollIntoView,
    });

    render(
      <ContextMenu
        point={{ x: 20, y: 20 }}
        onClose={vi.fn()}
        items={Array.from({ length: 20 }, (_, index) => ({ label: `Client ${index + 1}` }))}
      />,
    );
    scrollIntoView.mockClear();

    const first = screen.getByRole("menuitem", { name: "Client 1" });
    first.focus();
    fireEvent.keyDown(first, { key: "ArrowDown" });

    expect(screen.getByRole("menuitem", { name: "Client 2" })).toHaveFocus();
    expect(scrollIntoView).toHaveBeenLastCalledWith({ block: "nearest", inline: "nearest" });

    if (original) {
      Object.defineProperty(HTMLElement.prototype, "scrollIntoView", original);
    } else {
      delete (HTMLElement.prototype as { scrollIntoView?: unknown }).scrollIntoView;
    }
  });
});
