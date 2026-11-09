// The whole-list row ratchet (scripts/check-whole-list-rows.ts): which reads in a row component it names,
// which it leaves alone, and the marker that lets one stay.
import { expect, test } from "bun:test";
import path from "node:path";
import { compareToBaseline, findWholeListRows, readBaseline } from "../scripts/check-whole-list-rows";

const file = path.resolve(import.meta.dir, "a.tsx");
const lines = (found: string[]) => found.map((at) => Number(at.split(":").at(-1)));

test("a row that takes, binds, reads or scans a whole list is named", () => {
  const source = [
    "function SessionRow({ id, sessions }: Props) {",
    "  const session = sessions.find((s) => s.id === id);",
    "  return <div>{session?.title}</div>;",
    "}",
    "const AskItem = memo(function AskItem({ id }: { id: string }) {",
    "  const asks = useAsks();",
    "  const snap = useSyncExternalStore(store.subscribe, store.get);",
    "  const { rows } = useSyncExternalStore(store.subscribe, store.get);",
    "  return <span>{snap.sessions.length}</span>;",
    "});",
    "export const PaneCell = ({ snapshot, id }: P) => <b>{snapshot.rows.filter((r) => r.pane === id).length}</b>;",
  ].join("\n");
  expect(lines(findWholeListRows(file, source))).toEqual([1, 2, 6, 8, 9, 11]);
});

test("a component the file renders inside a .map is a row too", () => {
  const source = [
    "function Entry({ id }: { id: string }) {",
    "  const { sessions } = useContext(SessionsContext);",
    "  return <li>{sessions.length}</li>; // a length read is not a scan",
    "}",
    "export function List({ ids }: { ids: string[] }) {",
    "  return <ul>{ids.map((id) => <Entry key={id} id={id} />)}</ul>;",
    "}",
  ].join("\n");
  expect(lines(findWholeListRows(file, source))).toEqual([2]);
});

test("a list's own component, a group's own children and an unrelated hook are not named", () => {
  const source = [
    "export function SessionList() {",
    "  const sessions = useSessions();",
    "  return sessions.map((s) => <SessionRow key={s.id} session={s} />);",
    "}",
    "function SessionRow({ session }: { session: Session }) {",
    "  const entry = useSyncExternalStore(store.subscribe(session.id), () => store.get(session.id));",
    "  return <div>{entry.title}</div>;",
    "}",
    "function ToolGroupRow({ group }: { group: Group }) {",
    "  const failed = group.rows.filter((r) => r.failed).length;",
    "  const items = useTaskMenu(group);",
    "  return <div>{group.items.length + failed + items.length}</div>;",
    "}",
  ].join("\n");
  expect(findWholeListRows(file, source)).toEqual([]);
});

test("a whole-list-ok comment on the statement, above it, or above the component lets it stay", () => {
  const source = [
    "function SessionRow({ id, sessions }: Props) {",
    "  // whole-list-ok: the row shows how many siblings it has",
    "  const count = sessions.filter((s) => s.parent === id).length;",
    "  const first = sessions.find((s) => s.id === id); // whole-list-ok: bounded to 5 by the caller",
    "  return <div>{count}{first?.title}</div>;",
    "}",
    "// whole-list-ok: a summary card over every session, rendered once",
    "function SummaryCard({ sessions }: { sessions: Session[] }) {",
    "  return <div>{sessions.filter((s) => s.busy).length}</div>;",
    "}",
  ].join("\n");
  // The prop on line 1 has no marker; the reads in its body do.
  expect(lines(findWholeListRows(file, source))).toEqual([1]);
});

test("the baseline only moves down, and a row whose file is gone passes", () => {
  const baseline = readBaseline("# header\nsrc/a.tsx\t2\nsrc/b.tsx\t1\nsrc/gone.tsx\t3\n");
  const found = new Map([
    ["src/a.tsx", ["src/a.tsx:1", "src/a.tsx:2", "src/a.tsx:3"]],
    ["src/b.tsx", ["src/b.tsx:4"]],
  ]);
  const { grew, shrank } = compareToBaseline(found, baseline, (f) => f !== "src/gone.tsx");
  expect(grew.length).toBe(1);
  expect(grew[0]).toContain("src/a.tsx: 3 whole-list reads in rows, baseline 2");
  expect(shrank).toEqual([]);
  const fewer = compareToBaseline(new Map([["src/a.tsx", ["src/a.tsx:1"]]]), baseline, () => true);
  expect(fewer.shrank.map((s) => s.trim())).toEqual([
    "src/a.tsx: 1 whole-list reads in rows, baseline 2",
    "src/b.tsx: 0 whole-list reads in rows, baseline 1",
    "src/gone.tsx: 0 whole-list reads in rows, baseline 3",
  ]);
});
