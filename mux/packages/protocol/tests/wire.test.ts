import { expect, test } from "vite-plus/test";
import { parseClientFrame } from "../src/index.ts";

test("send frames keep only non-empty text parts", () => {
  const frame = parseClientFrame(
    JSON.stringify({
      type: "send",
      clientId: "c1",
      parts: [{ type: "text", text: "hi" }, { type: "text", text: "" }, { type: "bogus" }],
    }),
  );
  expect(frame).toEqual({ type: "send", clientId: "c1", parts: [{ type: "text", text: "hi" }] });
});

test("malformed frames are rejected", () => {
  expect(parseClientFrame("{")).toBeUndefined();
  expect(
    parseClientFrame(JSON.stringify({ type: "send", clientId: "c1", parts: [] })),
  ).toBeUndefined();
  expect(parseClientFrame(JSON.stringify({ type: "typing" }))).toBeUndefined();
  expect(parseClientFrame(new ArrayBuffer(1))).toBeUndefined();
});
