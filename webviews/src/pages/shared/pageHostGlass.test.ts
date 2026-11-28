import { describe, expect, test } from "bun:test";
import type { PageClient } from "./pageClient";
import { PAGE_HOST_GLASS_OP, reportPageHostGlass } from "./pageHostGlass";

// RFD 0207 "Host glass for pages": the op the page view serves, and nothing sent outside the App.
describe("reportPageHostGlass", () => {
  test("names the page view's op", () => {
    expect(PAGE_HOST_GLASS_OP).toBe("cmux.app.glass");
  });

  test("reports nothing with no client or outside the App", () => {
    const calls: string[] = [];
    const client = {
      call: async (op: string) => {
        calls.push(op);
        return undefined;
      },
    } as unknown as PageClient;
    const fakeDoc = {} as Document;
    const stopNone = reportPageHostGlass(null, fakeDoc, undefined, true);
    const stopMock = reportPageHostGlass(client, fakeDoc, undefined, false);
    stopNone();
    stopMock();
    expect(calls).toEqual([]);
  });
});
