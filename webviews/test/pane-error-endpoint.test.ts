// l10n-allow-file: dev middleware fixtures, not shipped UI.
import { afterAll, afterEach, expect, spyOn, test } from "bun:test";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import config from "../vite.config.acpmux-pane.mjs";

type Request = EventEmitter & { method: string; headers: Record<string, string>; destroy(): void };
type Response = { statusCode: number; end(): void };
type Handler = (request: Request, response: Response) => void;
const handlers = new Map<string, Handler>();
const plugin = config.plugins.find((plugin: { name?: string }) => plugin.name === "cmux-agent-pane-render-frame");
plugin.configureServer({ middlewares: { use: (route: string, handler: Handler) => handlers.set(route, handler) } });
const append = spyOn(fs, "appendFileSync").mockImplementation(() => {});
afterEach(() => append.mockClear());
afterAll(() => append.mockRestore());

function request(method = "POST", site = "same-origin") {
  let ended = false,
    destroyed = false;
  const response = {
    statusCode: 200,
    end() {
      ended = true;
    },
  };
  const incoming = Object.assign(new EventEmitter(), {
    method,
    headers: { "sec-fetch-site": site },
    destroy() {
      destroyed = true;
    },
  });
  handlers.get("/__cmux-pane-error")!(incoming, response);
  return { incoming, response, ended: () => ended, destroyed: () => destroyed };
}

test.each(["GET", "PUT", "OPTIONS"])("the error endpoint rejects %s without logging", (method) => {
  const call = request(method);
  expect(call.response.statusCode).toBe(405);
  expect(call.ended()).toBe(true);
  call.incoming.emit("data", Buffer.from("untrusted"));
  call.incoming.emit("end");
  expect(append).not.toHaveBeenCalled();
});

test.each(["cross-site", "same-site", "none", ""])("the error endpoint rejects fetch site %s", (site) => {
  const call = request("POST", site);
  expect(call.response.statusCode).toBe(403);
  expect(call.ended()).toBe(true);
  expect(append).not.toHaveBeenCalled();
});

test("same-origin POST logs at most 20 KB, measured as bytes", () => {
  const call = request();
  call.incoming.emit("data", Buffer.from("x".repeat(20000)));
  call.incoming.emit("end");
  expect(call.response.statusCode).toBe(204);
  expect(append.mock.calls[0]?.[1]).toBe("x".repeat(20000) + "\n");
});

test("oversized bodies abort during receipt and never append, even if end arrives", () => {
  const call = request();
  call.incoming.emit("data", Buffer.from("界".repeat(6666)));
  call.incoming.emit("data", Buffer.from("界"));
  expect(call.response.statusCode).toBe(413);
  expect(call.destroyed()).toBe(true);
  call.incoming.emit("end");
  expect(append).not.toHaveBeenCalled();
});
