/** The streamed reader of a listing's items (src/upstream/json-items.ts): item by item, with nothing else kept. */
import { expect, it } from "vitest";
import { JsonItemsError, jsonItemsScanner } from "../../src/upstream/json-items.ts";

const read = (text: string, chunk: number, field = "tunnels", maxItemChars = 1_000) => {
  const items: unknown[] = [];
  const scanner = jsonItemsScanner(field, maxItemChars, (item) => items.push(item));
  for (let i = 0; i < text.length; i += chunk) scanner.feed(text.slice(i, i + chunk));
  scanner.end();
  return items;
};

it("reads each item of the field, in any chunking, skipping every other field", () => {
  const doc = JSON.stringify({
    before: { tunnels: [{ no: 1 }], text: 'a "quoted" } ] { [ \\ value' },
    tunnels: [{ id: "t1", slug: "a}b", nested: { list: [1, { deep: "]" }] } }, { id: "t2", text: "é \u0000 \"x\"" }],
    after: [{ id: "not-this" }],
    totalCount: 2,
  });
  const expected = [{ id: "t1", slug: "a}b", nested: { list: [1, { deep: "]" }] } }, { id: "t2", text: "é \u0000 \"x\"" }];
  for (const chunk of [1, 2, 7, 64, doc.length]) expect(read(doc, chunk)).toEqual(expected);
  expect(read(JSON.stringify({ tunnels: [] }), 3)).toEqual([]);
  expect(read(` \n{ "tunnels" : [ { "id" : "x" } , {"id":"y"} ] }\n`, 5)).toEqual([{ id: "x" }, { id: "y" }]);
});

it("fails on an oversized item, a missing field, an item that is not an object, or a cut-off document", () => {
  expect(() => read(JSON.stringify({ tunnels: [{ id: "x".repeat(2_000) }] }), 100)).toThrow(JsonItemsError);
  expect(() => read(JSON.stringify({ other: [] }), 10)).toThrow(JsonItemsError);
  expect(() => read(JSON.stringify({ tunnels: ["x"] }), 10)).toThrow(JsonItemsError);
  expect(() => read(JSON.stringify({ tunnels: [1] }), 10)).toThrow(JsonItemsError);
  expect(() => read(JSON.stringify([{ tunnels: [] }]), 10)).toThrow(JsonItemsError);
  expect(() => read(JSON.stringify({ tunnels: [{ id: "x" }] }).slice(0, -2), 10)).toThrow(JsonItemsError);
});
