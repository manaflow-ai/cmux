import { describe, expect, test } from "bun:test";
import { strandedGatewayMode } from "./cloud-journey";

describe("strandedGatewayMode", () => {
  test("gateway mode with no gateway online is stranded", () => {
    expect(strandedGatewayMode({ gateway: { mode: "gateway", online: false } })).toBe(true);
    expect(strandedGatewayMode({ gateway: { mode: "gateway" } })).toBe(true);
  });
  test("an online gateway, off, joined or an unreadable answer is left alone", () => {
    expect(strandedGatewayMode({ gateway: { mode: "gateway", online: true } })).toBe(false);
    expect(strandedGatewayMode({ gateway: { mode: "off", online: false } })).toBe(false);
    expect(strandedGatewayMode({ gateway: { mode: "joined", online: false } })).toBe(false);
    expect(strandedGatewayMode(null)).toBe(false);
    expect(strandedGatewayMode({})).toBe(false);
  });
});
