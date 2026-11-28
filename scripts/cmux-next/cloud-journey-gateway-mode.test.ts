import { describe, expect, test } from "bun:test";
import { gatewayModeAction, strandedGatewayMode } from "./cloud-journey";

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

describe("gatewayModeAction", () => {
  test("a run with a login or a stub sets only a stranded team back to off", () => {
    expect(gatewayModeAction({ gateway: { mode: "gateway", online: false } }, false)).toBe("off");
    expect(gatewayModeAction({ gateway: { mode: "gateway", online: true } }, false)).toBe("keep");
    expect(gatewayModeAction({ gateway: { mode: "off", online: false } }, false)).toBe("keep");
  });
  test("a run whose only model route is the gateway never sets the team off (run 46059370159)", () => {
    expect(gatewayModeAction({ gateway: { mode: "off", online: false } }, true)).toBe("gateway");
    expect(gatewayModeAction({ gateway: { mode: "off", online: true } }, true)).toBe("gateway");
    expect(gatewayModeAction({ gateway: { mode: "gateway", online: true } }, true)).toBe("keep");
    expect(gatewayModeAction({ gateway: { mode: "gateway", online: false } }, true)).toBe("offline");
    expect(gatewayModeAction(null, true)).toBe("keep");
  });
});
