import { describe, expect, test } from "bun:test";
import { devHostParams, devHostReply } from "../src/dev-host/host";

describe("browser dev host", () => {
  const host = {
    endpoint: "ws://127.0.0.1:47901/",
    token: "test",
    cwd: "/work/cmux",
    editorOrigin: "http://127.0.0.1:4200",
  };

  test("accepts only loopback daemon links", () => {
    expect(devHostParams("#endpoint=ws%3A%2F%2F127.0.0.1%3A47901%2F&token=test")?.endpoint).toBe(host.endpoint);
    expect(devHostParams("#endpoint=wss%3A%2F%2Fexample.test%2F&token=test")).toBeUndefined();
    expect(
      devHostParams("#endpoint=ws%3A%2F%2F127.0.0.1%3A47901%2F&token=test&editor=https%3A%2F%2Fevil.test"),
    ).toBeUndefined();
  });

  test("confines file opens to the checkout", () => {
    expect(
      devHostReply(host, { id: "1", method: "file.open", params: { path: "/work/cmux/webviews/App.tsx" } }),
    ).toEqual(expect.objectContaining({ ok: true }));
    expect(devHostReply(host, { id: "2", method: "file.open", params: { path: "/work/other/secret.txt" } })).toEqual(
      expect.objectContaining({ ok: false }),
    );
    expect(
      devHostReply(host, { id: "3", method: "file.open", params: { path: "/work/cmux/../other/secret.txt" } }),
    ).toEqual(expect.objectContaining({ ok: false }));
  });
});
