// cmux#47677: Cmd+D beside a Cloud chat opens its page on that chat's Cloud machine. The page's route
// is then remote and owned-Cloud, and its Where must read Cloud, never This Mac.
import { expect, test } from "bun:test";
import { routeOnOwnCloud } from "./chatMachine";

test("a page whose route reaches the person's Cloud machine runs on Cloud", () => {
  expect(routeOnOwnCloud({ origin: "remote", ownerCloud: true })).toBe(true);
  expect(routeOnOwnCloud({ origin: "peer", ownerCloud: true })).toBe(true);
});

test("this Mac's page, or another machine that is not the person's Cloud one, is not", () => {
  expect(routeOnOwnCloud(undefined)).toBe(false);
  expect(routeOnOwnCloud({})).toBe(false);
  expect(routeOnOwnCloud({ ownerCloud: true })).toBe(false);
  expect(routeOnOwnCloud({ origin: "remote" })).toBe(false);
});
