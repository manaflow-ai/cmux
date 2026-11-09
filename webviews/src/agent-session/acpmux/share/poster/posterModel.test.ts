// l10n-allow-file: test fixtures.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../../model";
import {
  buildPoster,
  clip,
  hasPoster,
  lastFinishedTurn,
  posterDuration,
  posterLink,
  redact,
  wrap,
  REDACTED,
} from "./posterModel";
import { isPosterKey } from "./posterShortcut";

const row = (fields: Partial<AcpmuxRow> & { id: string; kind: string }): AcpmuxRow =>
  ({ version: 1, at: 0, ...fields }) as AcpmuxRow;

const edit = (id: string, path: string, oldText: string | undefined, newText: string): AcpmuxRow =>
  row({
    id,
    kind: "activity",
    items: [
      {
        kind: "tool",
        text: "",
        tool: { id, kind: "edit", title: "Edit", status: "completed", diffs: [{ path, oldText, newText }] },
      },
    ],
  } as Partial<AcpmuxRow> & { id: string; kind: string });

const turn = (prompt: string, at: number, ...middle: AcpmuxRow[]): AcpmuxRow[] => [
  row({ id: `p-${at}`, kind: "user", text: prompt, at }),
  ...middle,
  row({ id: `s-${at}`, kind: "turnSummary", at: at + 5_000, durationMs: 252_000 }),
];

test("redact hides env values, tokens and paths outside the project, and keeps paths inside it relative", () => {
  const text =
    "run OPENAI_API_KEY=sk-abc123def456ghi789jkl then open /Users/leo/secrets/notes.md and /repo/src/app.ts; " +
    "Authorization: Bearer abcdefghijklmnop token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 ~/dotfiles/zshrc";
  const out = redact(text, "/repo");
  expect(out).toContain(`OPENAI_API_KEY=${REDACTED}`);
  expect(out).not.toContain("sk-abc");
  expect(out).not.toContain("/Users/leo");
  expect(out).toContain("open … and src/app.ts");
  expect(out).toContain(`Bearer ${REDACTED}`);
  expect(out).not.toContain("ghp_");
  expect(out).not.toContain("dotfiles");
});

test("redact leaves ordinary prose, short slashes and words alone", () => {
  expect(redact("make the button blue and/or green on /settings", "/repo")).toBe(
    "make the button blue and/or green on /settings",
  );
});

test("wrap folds words to lines and ends a cut text with …", () => {
  expect(wrap("one two three four", 9, 3)).toEqual(["one two", "three", "four"]);
  const cut = wrap("alpha beta gamma delta epsilon zeta eta theta", 11, 2);
  expect(cut).toHaveLength(2);
  expect(cut[1]!.endsWith("…")).toBe(true);
  expect(clip("abcdefgh", 5)).toBe("abcd…");
  expect(clip("abc", 5)).toBe("abc");
});

test("the poster is the last finished turn, found from the end", () => {
  const rows = [
    ...turn("first", 1_000, edit("e1", "/repo/old.ts", "a", "b")),
    ...turn("make the header glass", 50_000, edit("e2", "/repo/src/Header.tsx", "x\ny\n", "x\nglass\nz\n")),
  ];
  expect(lastFinishedTurn(rows)?.[0]?.text).toBe("make the header glass");
  const poster = buildPoster(rows, { cwd: "/repo", harness: "Claude Code", model: "Opus 5.5" })!;
  expect(poster.prompt).toBe("make the header glass");
  expect(poster.files).toBe(1);
  expect(poster.added).toBeGreaterThan(0);
  expect(poster.hunks[0]?.path).toBe("src/Header.tsx");
  expect(poster.hunks[0]?.lines.some((line) => line.type === "add" && line.text === "glass")).toBe(true);
  expect(poster.durationMs).toBe(252_000);
  expect(poster.harness).toBe("Claude Code");
});

test("a turn still running makes no poster of itself: the one before it does", () => {
  const rows = [...turn("done one", 1_000), row({ id: "live", kind: "user", text: "still going", at: 9_000 })];
  expect(buildPoster(rows, {})?.prompt).toBe("done one");
  expect(hasPoster([row({ id: "only", kind: "user", text: "x" })])).toBe(false);
});

test("a file outside the project counts but shows no hunk", () => {
  const rows = turn(
    "edit both",
    1_000,
    edit("in", "/repo/a.ts", "1\n", "2\n"),
    edit("out", "/Users/leo/.zshrc", "x\n", "export TOKEN=abc\n"),
  );
  const poster = buildPoster(rows, { cwd: "/repo" })!;
  expect(poster.files).toBe(2);
  expect(poster.hunks.map((hunk) => hunk.path)).toEqual(["a.ts"]);
});

test("hunk lines are redacted too", () => {
  const rows = turn("add the key", 1_000, edit("env", "/repo/.env.example", "", "STRIPE_KEY=sk_live_abcdef\n"));
  const lines = buildPoster(rows, { cwd: "/repo" })!.hunks[0]!.lines.map((line) => line.text);
  expect(lines.join("\n")).toContain(`STRIPE_KEY=${REDACTED}`);
  expect(lines.join("\n")).not.toContain("sk_live");
});

test("the poster's cost does not grow with the chat: only the last turn's rows are read", () => {
  const reads = { count: 0 };
  const counted = (rows: AcpmuxRow[]) =>
    rows.map(
      (r) =>
        new Proxy(r, {
          get(target, key, receiver) {
            reads.count++;
            return Reflect.get(target, key, receiver);
          },
        }),
    );
  const measure = (turns: number) => {
    const rows = counted(
      Array.from({ length: turns }, (_, n) =>
        turn(`turn ${n}`, n * 10_000, edit(`e${n}`, `/repo/f${n}.ts`, "a\n", "b\n")),
      ).flat(),
    );
    reads.count = 0;
    buildPoster(rows, { cwd: "/repo" });
    return reads.count;
  };
  expect(measure(2_000)).toBe(measure(10));
});

test("durations, links and the key read as people say them", () => {
  expect(posterDuration(42_000)).toBe("42s");
  expect(posterDuration(252_000)).toBe("4m 12s");
  expect(posterDuration(3_900_000)).toBe("1h 5m");
  expect(posterLink("https://share.cmux.dev/v/abc/")).toBe("share.cmux.dev/v/abc");
  const key = { code: "KeyS", metaKey: true, altKey: true, shiftKey: false, ctrlKey: false };
  expect(isPosterKey(key)).toBe(true);
  expect(isPosterKey({ ...key, shiftKey: true })).toBe(false);
  expect(isPosterKey({ ...key, altKey: false })).toBe(false);
});

test("a file that resolves outside the project shows no hunk, whatever its spelling", () => {
  const out = (id: string, path: string, canonical?: string) =>
    row({
      id,
      kind: "activity",
      items: [
        {
          kind: "tool",
          text: "",
          tool: {
            id,
            kind: "edit",
            title: "Edit",
            status: "completed",
            diffs: [{ path, canonical, oldText: "a\n", newText: "b\n" }],
          },
        },
      ],
    } as Partial<AcpmuxRow> & { id: string; kind: string });
  const rows = turn(
    "edit around",
    1_000,
    out("up", "../secrets/.env"),
    out("link", "linked/notes.md", "/Users/leo/notes.md"),
    out("ok", "src/ok.ts", "/repo/src/ok.ts"),
  );
  const poster = buildPoster(rows, { cwd: "/repo" })!;
  expect(poster.files).toBe(3);
  expect(poster.hunks.map((hunk) => hunk.path)).toEqual(["src/ok.ts"]);
});

test("a summary the turn went on after does not finish it", () => {
  const rows = [
    ...turn("finished one", 1_000),
    row({ id: "p2", kind: "user", text: "still going", at: 9_000 }),
    row({ id: "s2", kind: "turnSummary", at: 9_500, continued: true } as Partial<AcpmuxRow> & {
      id: string;
      kind: string;
    }),
  ];
  expect(buildPoster(rows, {})?.prompt).toBe("finished one");
});

test("an outside path with spaces is hidden whole, quoted or not", () => {
  expect(redact("read '/Users/alice/secret notes.txt' now", "/repo")).toBe("read '…' now");
  expect(redact("read /Users/alice/secret notes.txt now", "/repo")).toBe("read … now");
  expect(redact("read /Users/alice/my\\ secret.txt now", "/repo")).toBe("read … now");
  expect(redact("fix /Users/alice/a.ts and README.md", "/repo")).toBe("fix … and README.md");
  expect(redact('open "/repo/src/my file.ts"', "/repo")).toBe('open "src/my file.ts"');
});

test("a file spelled through an outside link shows its path in the project", () => {
  const rows = turn(
    "edit through a link",
    1_000,
    row({
      id: "link",
      kind: "activity",
      items: [
        {
          kind: "tool",
          text: "",
          tool: {
            id: "link",
            kind: "edit",
            title: "Edit",
            status: "completed",
            diffs: [{ path: "/private/tmp/link.ts", canonical: "/repo/link.ts", oldText: "a\n", newText: "b\n" }],
          },
        },
      ],
    } as Partial<AcpmuxRow> & { id: string; kind: string }),
  );
  expect(buildPoster(rows, { cwd: "/repo" })!.hunks.map((hunk) => hunk.path)).toEqual(["link.ts"]);
});
