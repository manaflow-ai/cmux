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

it("checks the whole document's grammar, so a malformed listing hands over nothing the caller acts on", () => {
  const bad = [
    '{"tunnels":[{"id":"x"}]]}', // an extra closer
    '{"tunnels":[{"id":"x"}}]}', // a closer of the wrong kind
    '{"tunnels":[{"id":"x"}{"id":"y"}]}', // a missing comma between items
    '{"tunnels":[{"id":"x"} {"id":"y"}]}', // the same, with whitespace
    '{"a":1 "tunnels":[]}', // a missing comma between members
    '{"tunnels":[{"id":"x"},]}', // a trailing comma
    '{"tunnels":[,{"id":"x"}]}', // a leading comma
    '{"tunnels" [{"id":"x"}]}', // a missing colon
    '{"tunnels":[{"id":"x"}]} x', // trailing garbage
    '{"tunnels":[{"id":"x"}]}{}', // a second document
    '{"tunnels":[{"id":"x"}]', // the object unclosed
    '{"tunnels":[{"id":"x"}', // the array unclosed
    '{"tunnels":[{"id":"x"}],"count":tru}', // a malformed literal
    '{"tunnels":[{"id":"x"}],"count":01}', // a malformed number
    '{"tunnels":[{"id":"\\q"}]}', // an invalid escape
    '{"tunnels":[{"id":"\\u12g4"}]}', // a malformed \u escape
    '{"tunnels":[{"id":"a\nb"}]}', // a raw control character in a string
    '{"tunnels":[],"tunnels":[]}', // the field twice
    '{"tunnels":{"id":"x"}}', // the field not an array
    '{"tunnels":[{"id":"t1"}}}', // a mismatched closer after the items
    '{"tunnels":[{"id":"t1"}],"totalCount":}', // a missing value in a skipped field
    '{"before":{"a":[1,2}],"tunnels":[]}', // a mismatched closer in a skipped field
    '{"before":{"a" 1},"tunnels":[]}', // a missing colon in a skipped field
    '{"before":[1 2],"tunnels":[]}', // a missing comma in a skipped field
  ];
  for (const text of bad) {
    for (const chunk of [1, 5, text.length]) expect(() => read(text, chunk), text).toThrow(JsonItemsError);
  }
});

it("accepts closers, commas, colons and escapes inside strings", () => {
  const text = '{"note":"]}[{,:\\"\\\\\\/\\b\\f\\n\\r\\t\\u00e9","tunnels":[{"id":"x]}","s":"{[,\\"]"},{"id":"y","n":-1.5e+3,"t":true,"f":false,"z":null}],"totalCount":2}';
  for (const chunk of [1, 3, text.length]) {
    expect(read(text, chunk)).toEqual([{ id: "x]}", s: '{[,"]' }, { id: "y", n: -1500, t: true, f: false, z: null }]);
  }
});
