import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ConnectScreen } from "../src/components/ConnectScreen";

describe("ConnectScreen", () => {
  it("renders defaults, surfaces errors, and submits URL plus optional token", () => {
    const onConnect = vi.fn();
    render(<ConnectScreen connecting={false} error="Connection refused" onConnect={onConnect} />);
    expect(screen.getByLabelText("WebSocket URL")).toHaveValue("ws://127.0.0.1:7681");
    expect(screen.getByRole("alert")).toHaveTextContent("Connection refused");
    fireEvent.change(screen.getByLabelText("Token (optional)"), { target: { value: "secret" } });
    fireEvent.click(screen.getByRole("button", { name: "Connect" }));
    expect(onConnect).toHaveBeenCalledWith({ url: "ws://127.0.0.1:7681", token: "secret" });
  });
});
