// The unregistered-list ratchet (scripts/check-unregistered-lists.ts): which JSX list loops it names, which
// it leaves alone as constant, registered or capped, and the caps it refuses.
import { expect, test } from "bun:test";
import path from "node:path";
import { compareToBaseline } from "../scripts/check-whole-list-rows";
import { byDirectory, findUnregisteredLists, registerFixture } from "../scripts/check-unregistered-lists";

const file = path.resolve(import.meta.dir, "a.tsx");
const lines = (found: string[]) => found.map((at) => Number(at.split(":").at(-1)));
const find = (source: string[], options: Parameters<typeof findUnregisteredLists>[2] = {}) =>
  findUnregisteredLists(file, source.join("\n"), { read: () => undefined, ...options });

test("a map, flatMap, Array.from or loop that draws a list from data is named", () => {
  const source = [
    "export function Inbox({ threads, files }: Props) {",
    "  const rows = [];",
    "  for (const file of files) rows.push(<File key={file.id} file={file} />);",
    "  return (",
    "    <ul>",
    "      {threads.map((t) => <Thread key={t.id} thread={t} />)}",
    "      {threads.flatMap((t) => (t.pinned ? [<Pin key={t.id} />] : []))}",
    "      {Array.from(files, (f) => <li key={f.id}>{f.name}</li>)}",
    "      {rows}",
    "    </ul>",
    "  );",
    "}",
  ];
  expect(lines(find(source).loops)).toEqual([3, 6, 7, 8]);
});

test("a callback that returns no JSX, and React.Children.map, are not lists", () => {
  const source = [
    "export function Menu({ items, children }: Props) {",
    "  const options = items.map((item) => ({ value: item.id, label: item.name }));",
    "  return <Picker options={options}>{Children.map(children, (child) => <b>{child}</b>)}</Picker>;",
    "}",
  ];
  expect(find(source).loops).toEqual([]);
});

test("a helper in the file that returns JSX, and a row renderer passed in, draw a list", () => {
  const source = [
    "function row(entry: Entry) {",
    "  return entry.ok ? <Ok key={entry.id} /> : <Bad key={entry.id} />;",
    "}",
    "export function Lists({ entries, render }: Props) {",
    "  return <>{entries.map(row)}{entries.map((e, i) => render(e, i))}</>;",
    "}",
  ];
  expect(lines(find(source).loops)).toEqual([5, 5]);
});

test("a constant collection is not a list", () => {
  const source = [
    'const MODES = ["light", "dark"] as const;',
    "const KINDS = Object.freeze({ a: 1, b: 2 });",
    "enum Tone { Red, Blue }",
    "const SHOWN = 8;",
    "export function Settings({ log, wide }: Props) {",
    '  const tabs = [{ id: "a" }, { id: "b" }];',
    '  const shown = wide ? [...MODES, "auto"] : MODES;',
    "  return (",
    "    <div>",
    "      {MODES.map((m) => <Mode key={m} mode={m} />)}",
    "      {shown.filter(Boolean).map((m) => <Mode key={m} mode={m} />)}",
    "      {Object.keys(KINDS).map((k) => <Kind key={k} />)}",
    "      {Object.values(Tone).map((t) => <Swatch key={t} />)}",
    "      {tabs.map((tab) => <Tab key={tab.id} />)}",
    "      {Array.from({ length: 5 }, (_, i) => <Dot key={i} />)}",
    "      {log.slice(0, SHOWN).map((line) => <Line key={line.id} />)}",
    "      {log.slice(-3).map((line) => <Line key={line.id} />)}",
    "    </div>",
    "  );",
    "}",
  ];
  expect(find(source).loops).toEqual([]);
});

test("a slice or a length past 100, and a let, are still lists", () => {
  const source = [
    "const PAGE = 500;",
    "let MODES = ['a'];",
    "export function Log({ log }: Props) {",
    "  return (",
    "    <div>",
    "      {log.slice(0, PAGE).map((line) => <Line key={line.id} />)}",
    "      {Array.from({ length: 101 }, (_, i) => <Dot key={i} />)}",
    "      {MODES.map((m) => <b key={m}>{m}</b>)}",
    "    </div>",
    "  );",
    "}",
  ];
  expect(lines(find(source).loops)).toEqual([6, 7, 8]);
});

test("a loop in a registered component is not named; one in its neighbour is", () => {
  const source = [
    "export function ConversationList({ rows }: Props) {",
    "  return <ul>{rows.map((row) => <Row key={row.id} row={row} />)}</ul>;",
    "}",
    "export const Other = ({ rows }: Props) => <ul>{rows.map((row) => <Row key={row.id} row={row} />)}</ul>;",
  ];
  expect(lines(find(source, { registered: new Set(["ConversationList"]) }).loops)).toEqual([4]);
});

test("a list-cap naming a const number <= 100, in the file or its direct import, lets a loop stay", () => {
  const capFile = path.resolve(import.meta.dir, "caps.ts");
  const source = [
    'import { MAX_ACCOUNTS } from "./caps";',
    "const MAX_TEAMS = 20;",
    "export function Accounts({ accounts, teams }: Props) {",
    "  return (",
    "    <div>",
    "      {/* list-cap: MAX_ACCOUNTS */}",
    "      {accounts.map((a) => <Account key={a.id} />)}",
    "      {teams.map((t) => <Team key={t.id} />)} {/* list-cap: MAX_TEAMS */}",
    "    </div>",
    "  );",
    "}",
  ];
  const read = (name: string) => (name === capFile ? "export const MAX_ACCOUNTS = 4 * 8;" : undefined);
  expect(find(source, { read })).toEqual({ loops: [], badCaps: [] });
});

test("a list-cap over 100, or one that names no const number, always fails", () => {
  const source = [
    "const MAX_ROWS = 5_000;",
    "export function Rows({ rows, more }: Props) {",
    "  // list-cap: MAX_ROWS",
    "  const drawn = rows.map((r) => <Row key={r.id} />);",
    "  // list-cap: UNKNOWN",
    "  return <>{drawn}{more.map((r) => <Row key={r.id} />)}</>;",
    "}",
  ];
  const found = find(source);
  expect(found.loops).toEqual([]);
  expect(found.badCaps.map((cap) => cap.replace(/^.*?:(\d+):/, "$1:"))).toEqual([
    "3: list-cap MAX_ROWS is 5000, above 100; a list that long registers with the list contract",
    "5: list-cap UNKNOWN is not a const number in this file or its direct import",
  ]);
});

test("a cap covers only the loop it sits on, not every list in the same return", () => {
  const source = [
    "const MAX = 10;",
    "export function Two({ a, b }: Props) {",
    "  return (",
    "    <div>",
    "      {a.map((x) => <A key={x} />)} {/* list-cap: MAX */}",
    "      {b.map((x) => <B key={x} />)}",
    "    </div>",
    "  );",
    "}",
  ];
  expect(lines(find(source).loops)).toEqual([6]);
});

test("a fixture's source registers its component under src/", () => {
  const registry = new Map<string, Set<string>>();
  registerFixture(
    'export default listFixture({\n  source: "pages/home-channels/ConversationList.tsx#ConversationList",\n});',
    registry,
  );
  expect([...registry]).toEqual([["src/pages/home-channels/ConversationList.tsx", new Set(["ConversationList"])]]);
});

test("the baseline names the loops and only moves down", () => {
  const found = new Map([["src/a.tsx", ["src/a.tsx:3", "src/a.tsx:9"]]]);
  const { grew } = compareToBaseline(found, new Map([["src/a.tsx", 1]]), () => true, "unregistered list loops");
  expect(grew[0]).toContain("src/a.tsx: 2 unregistered list loops, baseline 1");
  const { shrank } = compareToBaseline(new Map(), new Map([["src/a.tsx", 1]]), () => true, "unregistered list loops");
  expect(shrank.map((s) => s.trim())).toEqual(["src/a.tsx: 0 unregistered list loops, baseline 1"]);
});

test("the baseline reads as one count per directory under src/, most first, and a total", () => {
  const counts = new Map([
    ["src/a/b/One.tsx", 2],
    ["src/a/b/Two.tsx", 3],
    ["src/a/Three.tsx", 1],
    ["src/Root.tsx", 1],
  ]);
  expect(byDirectory(counts)).toEqual(["  a/b 5", "  . 1", "  a 1", "  total 7 unregistered list loops in 4 files"]);
});
