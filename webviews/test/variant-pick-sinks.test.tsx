import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { act } from "react";
import { installDom, press, render, restoreDom, unmount } from "./viewer-empty-dom";
import type { PickRecord, PickSink } from "../src/ui/variant-pick/model";
import { recordPick, noopFeedSink } from "../src/ui/variant-pick/sinks";
import { beadsPickSink, type PickRequest } from "../src/ui/variant-pick/sinks";
import { RecordedVariantPick } from "../src/ui/variant-pick/RecordedVariantPick";
import { RenderVariantsPick } from "../src/agent-session/acpmux/conversation/RenderVariantsPick";
import { variantPickStrings } from "../src/ui/variant-pick/strings";
import table from "../src/ui/variant-pick/generated/strings.json";
const pick: PickRecord = {
  entryId: "ui.variant-pick",
  variantId: "a",
  recommendedId: "b",
  who: "forged",
  when: "forged",
  note: "why",
};
const receipt = { ...pick, who: "real@example.com", when: "2026-10-07T12:00:00Z" };

test("beads omits client identity/time and the feed receives the server receipt", async () => {
  let body: Record<string, unknown> = {};
  const request = (async (path, init) => {
    expect(path).toBe("/api/pick");
    body = JSON.parse(init!.body as string);
    return Response.json(receipt, { status: 201 });
  }) as PickRequest;
  const seen: PickRecord[] = [];
  const feed: PickSink = {
    record: async (record) => {
      seen.push(record);
      return record;
    },
  };
  expect(await recordPick(pick, beadsPickSink("cx-czd", request), feed)).toEqual(receipt);
  expect(body).toEqual({
    beadId: "cx-czd",
    entryId: "ui.variant-pick",
    variantId: "a",
    recommendedId: "b",
    note: "why",
  });
  expect(seen).toEqual([receipt]);
  expect(await noopFeedSink.record(receipt)).toEqual(receipt);
});

test("failed writes never reach the feed; malformed receipts fail", async () => {
  let feedCalls = 0;
  const feed: PickSink = {
    record: async (record) => {
      feedCalls++;
      return record;
    },
  };
  const failed = beadsPickSink("cx-czd", (async () => new Response("", { status: 403 })) as PickRequest);
  await expect(recordPick(pick, failed, feed)).rejects.toThrow();
  expect(feedCalls).toBe(0);
  for (const value of [
    {},
    { ...receipt, who: "" },
    { ...receipt, variantId: "c" },
    { ...receipt, threadId: "other" },
  ]) {
    const sink = beadsPickSink("cx-czd", (async () => Response.json(value)) as PickRequest);
    await expect(sink.record(pick)).rejects.toThrow();
  }
});

test("21 locales have matching keys and preserve option labels", () => {
  expect(Object.keys(table)).toHaveLength(21);
  for (const [locale, strings] of Object.entries(table)) {
    expect(Object.keys(strings).sort()).toEqual(Object.keys(table.en).sort());
    expect(variantPickStrings([locale]).format("pickLabel", "OPTION")).toContain("OPTION");
  }
  expect(variantPickStrings(["ja"]).t("recommended")).toBe("推奨");
});

beforeAll(installDom);
afterEach(unmount);
afterAll(restoreDom);

test("gallery recorder and thread adapter use the same picker", async () => {
  const records: PickRecord[] = [];
  const beads: PickSink = {
    record: async (value) => {
      const saved = { ...value, who: "viewer", when: receipt.when };
      records.push(saved);
      return saved;
    },
  };
  const root = await render(
    <RecordedVariantPick
      context={{ entryId: "ui.variant-pick" }}
      options={[
        { id: "a", label: "A" },
        { id: "b", label: "B" },
      ]}
      recommendedId="b"
      beads={beads}
    />,
  );
  await act(async () => (root.querySelectorAll("button")[1] as HTMLButtonElement).click());
  expect(root.querySelector('[aria-pressed="true"]')?.textContent).toBe("Picked");
  const thread = await render(
    <RenderVariantsPick
      calls={[
        { id: "call-a", title: "A" },
        { id: "call-b", title: "B", recommended: true },
      ]}
      threadId="thread-1"
      turnId="turn-2"
      beads={beads}
      feed={noopFeedSink}
      renderPreview={(call) => <p>{call.title}</p>}
    />,
  );
  const buttons = thread.querySelectorAll("button");
  act(() => buttons[0]!.focus());
  await press(buttons[0]!, "ArrowRight");
  await press(buttons[1]!, "Enter");
  expect(records.map((value) => [value.entryId, value.threadId, value.variantId, value.recommendedId])).toEqual([
    ["ui.variant-pick", undefined, "b", "b"],
    [undefined, "thread-1", "call-b", "call-b"],
  ]);
});

test("the gallery comparison posts its related bead and marks the confirmed option", async () => {
  const { GalleryVariantPick } = await import("../src/gallery/shell/GalleryVariantPick");
  const original = globalThis.fetch;
  const sent: Record<string, unknown>[] = [];
  globalThis.fetch = (async (_url: string, init: RequestInit) => {
    const value = JSON.parse(init.body as string);
    sent.push(value);
    return Response.json({ ...value, who: "viewer@example.com", when: receipt.when }, { status: 201 });
  }) as typeof fetch;
  try {
    const root = await render(
      <GalleryVariantPick
        locale="en"
        preview={(id) => <p>{id}</p>}
        entry={{
          id: "ui.variant-pick",
          title: "Fixture",
          area: "Pages",
          host: "native",
          covers: ["swift:Fixture"],
          pick: { beadId: "cx-czd", recommendedId: "b" },
          variants: { a: {}, b: {}, c: {} },
        }}
      />,
    );
    await act(async () => root.querySelectorAll("button")[2]!.click());
    expect(sent).toEqual([
      { beadId: "cx-czd", entryId: "ui.variant-pick", variantId: "c", recommendedId: "b", note: "" },
    ]);
    expect(root.querySelector('[aria-pressed="true"]')?.textContent).toBe("Picked");
  } finally {
    globalThis.fetch = original;
  }
});
