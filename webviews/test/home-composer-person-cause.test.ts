// A composer send (HomeOps.send) in the app names its op's client `transaction` to the host before
// the op goes out (`cmux.host.cause.person`, CmuxNextPages PagePersonCauseRoute),
// and the op carries that `transaction`, which the daemon echoes in `conversation-changed`. The
// host decides from its own record of a real key or click whether the echo is the person's; the
// Swift half is HomeComposerPersonCauseTests.
import { expect, test } from "bun:test";
import { DaemonHomeClient, PERSON_CAUSE_OP } from "../src/pages/home-channels/daemonHome";
import { HomeOps } from "../src/pages/home-channels/types";
import type { PageClient } from "../src/pages/shared/pageClient";
import type { DaemonSocket } from "../src/pages/shared/daemonSocket";

type Step = { to: "host" | "daemon"; op: string; params: Record<string, unknown> };

function daemon(steps: Step[]): DaemonSocket {
  return {
    async request(cmd: string, params: Record<string, unknown> = {}): Promise<unknown> {
      steps.push({ to: "daemon", op: cmd, params });
      if (cmd === "conversation-op") return { rev: 2, replayed: false };
      throw new Error(`not served: ${cmd}`);
    },
  } as unknown as DaemonSocket;
}

function host(steps: Step[], refuse = false): PageClient {
  return {
    async call<R>(op: string, params: unknown): Promise<R> {
      steps.push({ to: "host", op, params: params as Record<string, unknown> });
      if (refuse) throw Object.assign(new Error("unknown op"), { code: "cmux.page.unknown_op" });
      return { person: true } as R;
    },
    async subscribe() {
      return () => {};
    },
    handle() {
      return () => {};
    },
  };
}

const send = { conversation: "conv_local", text: "hi", idempotencyKey: "c1" };

test("a composer send names its transaction to the host, then sends the op with it", async () => {
  const steps: Step[] = [];
  const client = new DaemonHomeClient(daemon(steps), undefined, host(steps));
  await client.call(HomeOps.send, send);
  await client.call(HomeOps.send, { ...send, idempotencyKey: "c2" });
  expect(steps.map((step) => `${step.to} ${step.op}`)).toEqual([
    `host ${PERSON_CAUSE_OP}`,
    "daemon conversation-op",
    `host ${PERSON_CAUSE_OP}`,
    "daemon conversation-op",
  ]);
  const [claim, op, secondClaim, secondOp] = steps;
  expect(typeof claim.params.transaction).toBe("string");
  expect(String(claim.params.transaction)).toMatch(/^[\x21-\x7e]{1,128}$/);
  expect(op.params.transaction).toBe(claim.params.transaction);
  expect(op.params.idempotency_key).toBe("c1");
  expect(secondOp.params.transaction).toBe(secondClaim.params.transaction);
  expect(secondClaim.params.transaction).not.toBe(claim.params.transaction);
});

test("a host that refuses the claim still gets the send out", async () => {
  const steps: Step[] = [];
  const client = new DaemonHomeClient(daemon(steps), undefined, host(steps, true));
  await client.call(HomeOps.send, send);
  expect(steps.map((step) => step.to)).toEqual(["host", "daemon"]);
  expect(steps[1].params.transaction).toBe(steps[0].params.transaction);
});

test("in a browser (no host) the op goes out without a transaction", async () => {
  const steps: Step[] = [];
  const client = new DaemonHomeClient(daemon(steps));
  await client.call(HomeOps.send, send);
  expect(steps.map((step) => `${step.to} ${step.op}`)).toEqual(["daemon conversation-op"]);
  expect("transaction" in steps[0].params).toBe(false);
});
