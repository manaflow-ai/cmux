import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ConnectScreen } from "../src/components/ConnectScreen";

describe("ConnectScreen", () => {
  beforeEach(() => {
    window.localStorage.clear();
    window.history.replaceState({}, "", "/");
  });

  it("renders defaults, surfaces errors, and submits URL plus optional token", () => {
    const onConnect = vi.fn();
    render(<ConnectScreen connecting={false} error="Connection refused" onConnect={onConnect} />);
    expect(screen.getByLabelText("WebSocket URL")).toHaveValue("ws://127.0.0.1:7681");
    expect(screen.getByRole("alert")).toHaveTextContent("Connection refused");
    fireEvent.change(screen.getByLabelText("Token (optional)"), { target: { value: "secret" } });
    fireEvent.click(screen.getByRole("button", { name: "Connect" }));
    expect(onConnect).toHaveBeenCalledWith({ url: "ws://127.0.0.1:7681", token: "secret" });
    expect(window.localStorage.getItem("cmux-tui.web.lastWebSocketUrl")).toBe("ws://127.0.0.1:7681");
  });

  it("honors one-tap URL and token query parameters", () => {
    window.history.replaceState({}, "", "/?ws=wss%3A%2F%2Fexample.test%3A8443&token=one-tap");
    const onConnect = vi.fn();
    render(<ConnectScreen connecting={false} error={null} onConnect={onConnect} />);
    expect(screen.getByLabelText("WebSocket URL")).toHaveValue("wss://example.test:8443");
    expect(screen.getByLabelText("Token (optional)")).toHaveValue("one-tap");
  });
});
