import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ConnectScreen } from "../src/components/ConnectScreen";

describe("ConnectScreen", () => {
  beforeEach(() => {
    window.localStorage.clear();
    window.history.replaceState({}, "", "/");
  });

  it("renders defaults, surfaces errors, and starts pairing", () => {
    const onConnect = vi.fn();
    render(<ConnectScreen connecting={false} error="Connection refused" pairing={null} onConnect={onConnect} />);
    expect(screen.getByLabelText("WebSocket URL")).toHaveValue("ws://127.0.0.1:7681");
    expect(screen.getByRole("alert")).toHaveTextContent("Connection refused");
    fireEvent.click(screen.getByRole("button", { name: "Connect" }));
    expect(onConnect).toHaveBeenCalledWith({ url: "ws://127.0.0.1:7681", token: undefined });
    expect(window.localStorage.getItem("cmux-tui.web.lastWebSocketUrl")).toBe("ws://127.0.0.1:7681");
  });

  it("honors a one-tap socket query and token fragment, then removes both", () => {
    window.history.replaceState(
      {},
      "",
      "/?ws=wss%3A%2F%2Fexample.test%3A8443#view=docs%2Fintro&token=one-tap&section",
    );
    const onConnect = vi.fn();
    render(<ConnectScreen connecting={false} error={null} pairing={null} onConnect={onConnect} />);
    expect(screen.getByLabelText("WebSocket URL")).toHaveValue("wss://example.test:8443");
    fireEvent.click(screen.getByRole("button", { name: "Connect" }));
    expect(onConnect).toHaveBeenCalledWith({ url: "wss://example.test:8443", token: "one-tap" });
    expect(window.location.search).toBe("");
    expect(window.location.hash).toBe("#view=docs%2Fintro&section");
  });

  it("preserves an ordinary fragment verbatim while consuming a socket query", () => {
    window.history.replaceState({}, "", "/?ws=wss%3A%2F%2Fexample.test%3A8443#docs/intro");
    render(<ConnectScreen connecting={false} error={null} pairing={null} onConnect={vi.fn()} />);
    expect(window.location.search).toBe("");
    expect(window.location.hash).toBe("#docs/intro");
  });

  it("shows the comparison code while the TUI decision is pending", () => {
    render(<ConnectScreen
      connecting={false}
      error={null}
      pairing={{ id: 7, code: "123 456", peer: "127.0.0.1", expiresIn: 60 }}
      onConnect={vi.fn()}
    />);
    expect(screen.getByRole("status")).toHaveTextContent("123 456");
    expect(screen.getByRole("button", { name: "Waiting for approval…" })).toBeDisabled();
  });
});
