import { describe, expect, test } from "bun:test";
import { singleConversation } from "./single";

describe("singleConversation", () => {
  test("reads the conversation the host's route names", () => {
    expect(singleConversation("#/conversation/conv_local")).toBe("conv_local");
    expect(singleConversation("#/conversation/conv%3Aa.b-c")).toBe("conv:a.b-c");
  });

  test("anything else is the docked Home's list", () => {
    expect(singleConversation("")).toBeUndefined();
    expect(singleConversation("#/conversation/")).toBeUndefined();
    expect(singleConversation("#/conversation/a/b")).toBeUndefined();
    expect(singleConversation("#/conversation/%E0%A4%A")).toBeUndefined();
    expect(singleConversation("#/conversation/a%20b")).toBeUndefined();
    expect(singleConversation("#/settings")).toBeUndefined();
  });
});
