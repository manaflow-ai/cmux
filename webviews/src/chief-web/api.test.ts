import { afterEach, expect, spyOn, test } from "bun:test";
import {
  chiefApi,
  ChiefAccessDenied,
  ChiefApiError,
  ChiefUnavailable,
  InvalidClientMessageId,
  SendRefused,
} from "./api";
import { ChiefAccessError, ExpiredSession } from "./wire";

const identity = { chiefId: "chief_1", mainConversationId: "conv_1", handle: "alex" };
const ticket = { ticket: "single-use-ticket", websocketUrl: "wss://example.test/v1/chief/wire" };
const signal = () => new AbortController().signal;
let fetchMock: ReturnType<typeof spyOn<typeof globalThis, "fetch">> | undefined;

afterEach(() => {
  fetchMock?.mockRestore();
  fetchMock = undefined;
});

function respond(body: unknown, status = 200) {
  fetchMock = spyOn(globalThis, "fetch").mockImplementation(
    Object.assign(async () => Response.json(body, { status }), { preconnect: globalThis.fetch.preconnect }),
  );
  return fetchMock;
}

test("me uses only the settled identity and includes the same-origin cookie", async () => {
  const fetch = respond({ ...identity, user: "must-not-be-used", wire_url: "must-not-be-used" });
  expect(await chiefApi.me(signal())).toEqual(identity);
  expect(fetch).toHaveBeenCalledTimes(1);
  const [url, options] = fetch.mock.calls[0]!;
  expect(url).toBe("/v1/chief/me");
  expect(options?.method).toBe("GET");
  expect(options?.credentials).toBe("include");
  expect(options?.body).toBeUndefined();
  expect(new Headers(options?.headers).has("Authorization")).toBe(false);
});

test("ticket is a bodyless POST returning both ticket and socket URL", async () => {
  const fetch = respond(ticket);
  expect(await chiefApi.ticket(signal())).toEqual(ticket);
  const [url, options] = fetch.mock.calls[0]!;
  expect(url).toBe("/v1/chief/ticket");
  expect(options?.method).toBe("POST");
  expect(options?.credentials).toBe("include");
  expect(options?.body).toBeUndefined();
  expect(new Headers(options?.headers).has("Content-Type")).toBe(false);
});

test("message retry preserves clientMessageId and uses the settled body", async () => {
  const fetch = respond({ ok: true, clientMessageId: "same-id_42", receipt: { id: "receipt_1" } });
  await chiefApi.send("Build me a hello page", "same-id_42", signal());
  await chiefApi.send("Build me a hello page", "same-id_42", signal());
  expect(fetch).toHaveBeenCalledTimes(2);
  for (const [url, options] of fetch.mock.calls) {
    expect(url).toBe("/v1/chief/messages");
    expect(options?.method).toBe("POST");
    expect(options?.credentials).toBe("include");
    expect(new Headers(options?.headers).get("Content-Type")).toBe("application/json");
    expect(JSON.parse(String(options?.body))).toEqual({
      text: "Build me a hello page",
      clientMessageId: "same-id_42",
    });
  }
});

test("HTTP 200 with ok:false rejects the message", async () => {
  respond({ ok: false, clientMessageId: "id_1", receipt: { code: "rejected" } });
  await expect(chiefApi.send("Build", "id_1", signal())).rejects.toBeInstanceOf(SendRefused);
});

test("message receipt must acknowledge the submitted id", async () => {
  respond({ ok: true, clientMessageId: "different", receipt: {} });
  await expect(chiefApi.send("Build", "id_1", signal())).rejects.toBeInstanceOf(ChiefApiError);
});

for (const clientId of ["", "spaces are invalid", "bad.id", "x".repeat(129)]) {
  test(`invalid client id is rejected before a request (${JSON.stringify(clientId)})`, async () => {
    const fetch = respond({ ok: true });
    await expect(chiefApi.send("Build", clientId, signal())).rejects.toBeInstanceOf(InvalidClientMessageId);
    expect(fetch).not.toHaveBeenCalled();
  });
}

for (const [name, invoke] of [
  ["me", () => chiefApi.me(signal())],
  ["ticket", () => chiefApi.ticket(signal())],
  ["messages", () => chiefApi.send("Build", "id_1", signal())],
] as const) {
  test(`${name}: 401 means signed out`, async () => {
    respond({ code: "unauthenticated", message: "Sign in required" }, 401);
    await expect(invoke()).rejects.toBeInstanceOf(ExpiredSession);
  });
  for (const status of [403, 404] as const) {
    test(`${name}: ${status} is inaccessible, not signed out`, async () => {
      respond({ code: "chief.not_found", message: "Not your Chief" }, status);
      const error = await invoke().catch((failure: unknown) => failure);
      expect(error).toBeInstanceOf(ChiefAccessError);
      expect(error).toBeInstanceOf(ChiefAccessDenied);
      expect(error).not.toBeInstanceOf(ExpiredSession);
      expect(error).toMatchObject({ status, code: "chief.not_found", message: "Not your Chief" });
    });
  }
  test(`${name}: 503 remains a retryable service failure`, async () => {
    respond({ code: "chief.unavailable", message: "Chief is starting" }, 503);
    const error = await invoke().catch((failure: unknown) => failure);
    expect(error).toBeInstanceOf(ChiefUnavailable);
    expect(error).not.toBeInstanceOf(ExpiredSession);
    expect(error).not.toBeInstanceOf(SendRefused);
    expect(error).toMatchObject({ status: 503, code: "chief.unavailable", message: "Chief is starting" });
  });
}

test("the request signal follows caller cancellation", async () => {
  const fetch = respond(identity);
  const controller = new AbortController();
  await chiefApi.me(controller.signal);
  const requestSignal = fetch.mock.calls[0]![1]?.signal;
  expect(requestSignal?.aborted).toBe(false);
  controller.abort();
  expect(requestSignal?.aborted).toBe(true);
});
