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
      pairing={{ id: 7n, code: "123 456", peer: "127.0.0.1", expiresIn: 60 }}
      onConnect={vi.fn()}
    />);
    expect(screen.getByRole("status")).toHaveTextContent("123 456");
    expect(screen.getByRole("button", { name: "Waiting for approval…" })).toBeDisabled();
  });

  it("collects a Mac bridge grant in the message body configuration", () => {
    window.history.replaceState({}, "", "/?runtime=mac");
    const onConnect = vi.fn();
    render(<ConnectScreen connecting={false} error={null} pairing={null} onConnect={onConnect} />);
    expect(screen.getByLabelText("Runtime")).toHaveValue("mac");
    expect(screen.getByLabelText("WebSocket URL")).toHaveValue("ws://127.0.0.1:7683/cmux");
    fireEvent.change(screen.getByLabelText("Mac bridge grant token"), {
      target: { value: "cmux_web_test" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Connect" }));
    expect(onConnect).toHaveBeenCalledWith({
      url: "ws://127.0.0.1:7683/cmux",
      token: "cmux_web_test",
      runtime: "mac",
    });
  });

  it("switches between independently remembered runtime endpoints", () => {
    window.localStorage.setItem("cmux-tui.web.lastWebSocketUrl", "wss://tui.example.test:8443");
    window.localStorage.setItem("cmux-mac.web.lastWebSocketUrl", "wss://mac.example.test/cmux");
    render(<ConnectScreen connecting={false} error={null} pairing={null} onConnect={vi.fn()} />);
    expect(screen.getByLabelText("WebSocket URL")).toHaveValue("wss://tui.example.test:8443");

    fireEvent.change(screen.getByLabelText("Runtime"), { target: { value: "mac" } });
    expect(screen.getByLabelText("WebSocket URL")).toHaveValue("wss://mac.example.test/cmux");
  });

  it("restores a manually selected Mac runtime without persisting its token", () => {
    const first = render(
      <ConnectScreen connecting={false} error={null} pairing={null} onConnect={vi.fn()} />,
    );
    fireEvent.change(screen.getByLabelText("Runtime"), { target: { value: "mac" } });
    fireEvent.change(screen.getByLabelText("Mac bridge grant token"), {
      target: { value: "cmux_web_secret" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Connect" }));
    expect(window.location.search).toBe("?runtime=mac");
    first.unmount();

    render(<ConnectScreen connecting={false} error="Reconnect" pairing={null} onConnect={vi.fn()} />);
    expect(screen.getByLabelText("Runtime")).toHaveValue("mac");
    expect(screen.getByLabelText("Mac bridge grant token")).toHaveValue("");
  });

  it("never sends a Mac fragment grant to a TUI runtime", () => {
    window.history.replaceState({}, "", "/?runtime=mac#token=cmux_web_secret");
    const onConnect = vi.fn();
    render(<ConnectScreen connecting={false} error={null} pairing={null} onConnect={onConnect} />);
    expect(screen.getByLabelText("Mac bridge grant token")).toHaveValue("cmux_web_secret");

    fireEvent.change(screen.getByLabelText("Runtime"), { target: { value: "tui" } });
    fireEvent.click(screen.getByRole("button", { name: "Connect" }));

    expect(onConnect).toHaveBeenCalledWith({
      url: "ws://127.0.0.1:7681",
      token: undefined,
    });
  });

  it("never pre-fills a Mac grant from a TUI fragment credential", () => {
    window.history.replaceState({}, "", "/#token=tui-secret");
    render(<ConnectScreen connecting={false} error={null} pairing={null} onConnect={vi.fn()} />);

    fireEvent.change(screen.getByLabelText("Runtime"), { target: { value: "mac" } });
    expect(screen.getByLabelText("Mac bridge grant token")).toHaveValue("");
  });
});
