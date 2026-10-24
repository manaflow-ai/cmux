// A cmux page says when its start is done (`{t: "booted"}`, pageClient.ts), so the host's
// hibernation may freeze it while nobody sees it (perf-lead.md F3, PageWebView+ChromiumCost.swift)
// without stopping what the start still does: a chat hidden at document start still sends its
// seeded prompt. The page says it once: after the document loaded and its first screen's data is
// in (the paint gate, paintGate.ts), and never while it is a parked spare (only after its claim).
import { describe, expect, test } from "bun:test";
import { BOOTED, BridgePageClient, CLAIM_OP, PARKED_NAME, RECEIVE_NAME } from "../src/pages/shared/pageClient";
import { PAINT_AFTER_NAME } from "../src/pages/shared/paintGate";

type Posted = { t: string; id?: number };

/** A stand-in host that records what the page posts and answers every call. */
function host() {
  const posted: Posted[] = [];
  return {
    posted,
    handler: {
      async postMessage(body: unknown): Promise<unknown> {
        const envelope = body as Posted;
        posted.push(envelope);
        return envelope.t === "call" ? { t: "ok", id: envelope.id, value: null } : null;
      },
    },
  };
}

/** A window stand-in whose document is still loading until `load()`. */
function loadingTarget(extra: Record<string, unknown> = {}) {
  let onLoad: (() => void) | undefined;
  const target: Record<string, unknown> = {
    ...extra,
    document: { readyState: "loading" },
    addEventListener(name: string, listener: () => void) {
      if (name === "load") onLoad = listener;
    },
  };
  return { target, load: () => onLoad?.() };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const booted = (posted: Posted[]) => posted.filter((envelope) => envelope.t === BOOTED.t).length;

describe("the page's booted signal", () => {
  test("goes once, after the document loaded", async () => {
    const { posted, handler } = host();
    const { target, load } = loadingTarget();
    const client = new BridgePageClient(handler, target);
    await client.call("cmux.test.read", {});
    await settle();
    expect(booted(posted)).toBe(0);

    load();
    await settle();
    expect(booted(posted)).toBe(1);
    await client.call("cmux.test.read", {});
    await settle();
    expect(booted(posted)).toBe(1);
  });

  test("waits for the page's first-screen gate", async () => {
    const { posted, handler } = host();
    let ready: () => void = () => {};
    const gate = new Promise<void>((resolve) => (ready = resolve));
    const { target, load } = loadingTarget({ [PAINT_AFTER_NAME]: gate });
    new BridgePageClient(handler, target);
    load();
    await settle();
    expect(booted(posted)).toBe(0);

    ready();
    await settle();
    expect(booted(posted)).toBe(1);
  });

  test("a parked spare says it only after its claim", async () => {
    const { posted, handler } = host();
    const { target, load } = loadingTarget({ [PARKED_NAME]: true });
    new BridgePageClient(handler, target);
    load();
    await settle();
    expect(booted(posted)).toBe(0);

    const receive = target[RECEIVE_NAME] as (message: unknown) => void;
    receive({ t: "call", id: 1, op: CLAIM_OP, params: {} });
    await settle();
    expect(booted(posted)).toBe(1);
  });
});
