import { expect, test } from "bun:test";
import type { PageClient, PageHandler } from "../../pages/shared/pageClient";
import { POOL_RETARGET_OP, parseRetarget, servePoolRetarget } from "./poolRetarget";

function fakePage() {
  const handlers = new Map<string, PageHandler>();
  const page: PageClient = {
    call: async <R>() => undefined as R,
    subscribe: async () => () => {},
    handle: (op, handler) => {
      handlers.set(op, handler);
      return () => handlers.delete(op);
    },
  };
  const call = (params: unknown) => {
    const h = handlers.get(POOL_RETARGET_OP);
    if (!h) throw new Error("not served");
    return Promise.resolve(h(params));
  };
  return { page, handlers, call };
}

test("parseRetarget refuses a missing or empty session", () => {
  expect(() => parseRetarget(undefined)).toThrow();
  expect(() => parseRetarget({ session: "" })).toThrow();
  expect(() => parseRetarget({ session: 4 })).toThrow();
  expect(parseRetarget({ session: "s1" })).toBe("s1");
});

test("a retarget switches once; the same session again is a no-op", async () => {
  const { page, call } = fakePage();
  const seen: string[] = [];
  const pool = servePoolRetarget(page, (s) => void seen.push(s));
  expect(await call({ session: "a" })).toEqual({ session: "a", switched: true });
  expect(await call({ session: "a" })).toEqual({ session: "a", switched: false });
  expect(seen).toEqual(["a"]);
  expect(pool.current()).toBe("a");
});

test("the latest retarget wins over one still switching", async () => {
  const { page, call } = fakePage();
  let release!: () => void;
  const pool = servePoolRetarget(page, (s) =>
    s === "slow" ? new Promise<void>((r) => (release = r)) : undefined,
  );
  const first = call({ session: "slow" });
  const second = await call({ session: "fast" });
  release();
  expect(await first).toEqual({ session: "slow", switched: false, superseded: true });
  expect(second).toEqual({ session: "fast", switched: true });
  expect(pool.current()).toBe("fast");
});

test("dispose stops serving the op", () => {
  const { page, handlers } = fakePage();
  servePoolRetarget(page, () => {}).dispose();
  expect(handlers.has(POOL_RETARGET_OP)).toBe(false);
});
