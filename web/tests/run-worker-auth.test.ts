import { afterEach, describe, expect, test } from "bun:test";
import { isRunWorkerAuthorized } from "../services/runs/workerAuth";

const previousToken = process.env.CMUX_RUN_WORKER_TOKEN;

afterEach(() => {
  if (previousToken === undefined) delete process.env.CMUX_RUN_WORKER_TOKEN;
  else process.env.CMUX_RUN_WORKER_TOKEN = previousToken;
});

describe("Run worker ingestion authorization", () => {
  test("fails closed when the server-side worker token is absent", () => {
    delete process.env.CMUX_RUN_WORKER_TOKEN;
    expect(isRunWorkerAuthorized(new Request("https://cmux.test/api/runs/run/attempts/attempt/events", {
      headers: { "x-cmux-run-worker-token": "anything" },
    }))).toBe(false);
  });

  test("accepts only the exact configured token and never a bearer token", () => {
    process.env.CMUX_RUN_WORKER_TOKEN = "worker-secret";
    const url = "https://cmux.test/api/runs/run/attempts/attempt/events";
    expect(isRunWorkerAuthorized(new Request(url, { headers: { "x-cmux-run-worker-token": "worker-secret" } }))).toBe(true);
    expect(isRunWorkerAuthorized(new Request(url, { headers: { "x-cmux-run-worker-token": "wrong" } }))).toBe(false);
    expect(isRunWorkerAuthorized(new Request(url, { headers: { authorization: "Bearer worker-secret" } }))).toBe(false);
  });

  test("trims deployment and presented values without accepting a suffix", () => {
    process.env.CMUX_RUN_WORKER_TOKEN = " worker-secret ";
    const url = "https://cmux.test/api/runs/run/attempts/attempt/events";
    expect(isRunWorkerAuthorized(new Request(url, { headers: { "x-cmux-run-worker-token": " worker-secret " } }))).toBe(true);
    expect(isRunWorkerAuthorized(new Request(url, { headers: { "x-cmux-run-worker-token": "worker-secret-extra" } }))).toBe(false);
  });
});
