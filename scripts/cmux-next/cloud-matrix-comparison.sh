set -euo pipefail
base=bee84039c3b5c527aeecbc4044fca6956649fd7f
head=${HEAD_SHA:-$(git rev-parse HEAD)}
test "$(git rev-parse HEAD)" = "$head"
bun test scripts/cmux-next/cloud-claude-matrix.test.ts scripts/cmux-next/cloud-chat-matrix.test.ts
python3 scripts/cmux-next/test_cloud_chat_matrix.py

# Use the same CLI options and absent credentials on both revisions. These
# selections are skipped before any machine or model can be started.
tmp_dir=$(mktemp -d)
for rev in "$base" "$head"; do
    tree="$tmp_dir/$rev"
    mkdir -p "$tree"
    git archive HEAD scripts/cmux-next | tar -x -C "$tree"
    if test "$rev" = "$base"; then
        (cd "$tree" && patch --batch -s -p1) <<'BASE_DIFF'
diff --git a/scripts/cmux-next/cloud-chat-matrix.ts b/scripts/cmux-next/cloud-chat-matrix.ts
index ce498b93d0a..d56e83e470b 100644
--- a/scripts/cmux-next/cloud-chat-matrix.ts
+++ b/scripts/cmux-next/cloud-chat-matrix.ts
@@ -21,7 +21,7 @@
  *
  * Other lanes add their cells to CELLS (the Claude cells: lane cloud-claude-matrix). --out DIR gets one
  * folder per cell (journey.json, summary.md) and matrix.md, the table for the results issue. Exit 0 only
- * when at least one cell passed and none failed. A run with no judged cells exits 2.
+ * when no cell failed.
  */
 import { spawnSync } from "node:child_process";
 import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
@@ -184,18 +184,9 @@ export function judge(cell: Cell, steps: Step[], exit: number): Row {
   }
   if (failed.length) return { cell, verdict: "fail", why: `${failed[0]!.step}: ${(failed[0]!.detail ?? "").slice(0, 200)}`, ms, reply };
   if (exit !== 0) return { cell, verdict: "fail", why: `journey exit ${exit}`, ms, reply };
-  const proofStep = cell.proof === "bench" ? "start bench" : "reply";
-  if (!steps.some((s) => s.step === proofStep && s.status === "pass")) {
-    return { cell, verdict: "fail", why: `no successful ${proofStep} step`, ms, reply };
-  }
   return { cell, verdict: "pass", why: "every step passed", ms, reply };
 }
 
-export function matrixVerdict(rows: Row[]): Row["verdict"] {
-  if (rows.some((row) => row.verdict === "fail")) return "fail";
-  return rows.some((row) => row.verdict === "pass") ? "pass" : "skip";
-}
-
 export function table(rows: Row[]): string {
   const head = `| Cell | Agent | Sign-in | Proof | Result | First reply | Turn 2 | Pause / resume | Turn after resume | Why |\n|---|---|---|---|---|---|---|---|---|---|`;
   const t = (n?: number) => (n === undefined ? "-" : n >= 10_000 ? `${(n / 1000).toFixed(0)} s` : `${(n / 1000).toFixed(1)} s`);
@@ -264,11 +255,10 @@ export function main(argv: string[]): number {
     if (existsSync(bench)) extra.push(readFileSync(bench, "utf8"));
     console.log(`${row.verdict.toUpperCase()} ${cell.id} ${((Date.now() - t0) / 1000).toFixed(0)} s :: ${row.why}`);
   }
-  const verdict = matrixVerdict(rows);
-  const md = `${verdict.toUpperCase()}: Cloud chat matrix\n\n${table(rows)}\n${extra.map((e) => `\n${e}`).join("")}`;
+  const md = `${table(rows)}\n${extra.map((e) => `\n${e}`).join("")}`;
   writeFileSync(path.join(out, "matrix.md"), md);
   console.log(`\n${md}\nmatrix: ${path.join(out, "matrix.md")}`);
-  return { fail: 1, pass: 0, skip: 2 }[verdict];
+  return rows.some((r) => r.verdict === "fail") ? 1 : 0;
 }
 
 if (import.meta.main) process.exit(main(process.argv.slice(2)));
diff --git a/scripts/cmux-next/cloud-claude-matrix.ts b/scripts/cmux-next/cloud-claude-matrix.ts
index 0577aeb900c..644dc5ad1ac 100644
--- a/scripts/cmux-next/cloud-claude-matrix.ts
+++ b/scripts/cmux-next/cloud-claude-matrix.ts
@@ -25,7 +25,7 @@
  *   subscription  a Claude Pro/Max login, CLAUDE_CODE_OAUTH_TOKEN, sent with the agent's start as the app sends a Cloud model connection (cmux#40159)
  *   api-key       ANTHROPIC_API_KEY, put in Claude's settings on the machine (the chat card's API-key route)
  *   team-key      a key from the team's settings (CMUX_MATRIX_TEAM_KEY_TEAM names the team that has one)
- * A row whose credential is absent is SKIP with the reason. An all-skipped run exits 2 (0 for --plan).
+ * A row whose credential is absent is SKIP with the reason, never a pass. Exit 0 only when no run cell failed.
  * Secrets come from the environment or --credentials only and are never printed (the journey scrubs its output).
  */
 import { spawn } from "node:child_process";
@@ -41,7 +41,7 @@ export const CHATS = ["first", "followup", "resume", "parallel"] as const;
 export type Chat = (typeof CHATS)[number];
 export type CellStatus = "pass" | "fail" | "skip";
 export type Cell = { status: CellStatus; detail: string };
-export type Row = { auth: Auth; model: string; cells: Record<Chat, Cell>; replyMs?: number; createToReplyMs?: number; reply?: string; journeyError?: string };
+export type Row = { auth: Auth; model: string; cells: Record<Chat, Cell>; replyMs?: number; createToReplyMs?: number; reply?: string };
 
 const STEP: Record<Exclude<Chat, "parallel">, string> = { first: "reply", followup: "turn 2 (same session)", resume: "turn after resume" };
 
@@ -75,8 +75,6 @@ export function rowFromSteps(auth: Auth, model: string, steps: Step[], exitCode:
   const create = steps.findIndex((s) => s.step === "create machine");
   const reply = steps.findIndex((s) => s.step === "reply");
   const row: Row = { auth, model, cells };
-  if (firstFailed) row.journeyError = `${firstFailed.step}: ${firstFailed.detail.slice(0, 200)}`;
-  else if (exitCode !== 0) row.journeyError = `journey exit ${exitCode}`;
   if (reply >= 0 && steps[reply].status === "pass") {
     row.replyMs = steps[reply].ms;
     row.reply = steps[reply].detail.slice(0, 120);
@@ -95,14 +93,10 @@ export function parallelCell(rows: Row[]): Cell {
 const sec = (ms?: number) => (ms === undefined ? "" : `${(ms / 1000).toFixed(1)} s`);
 const mark = (c: Cell) => (c.status === "pass" ? "pass" : c.status === "fail" ? "**FAIL**" : "skip");
 
-export function matrixStatus(rows: Row[]): CellStatus {
-  if (rows.some((r) => r.journeyError || CHATS.some((c) => r.cells[c].status === "fail"))) return "fail";
-  return rows.some((r) => r.cells.first.status === "pass") ? "pass" : "skip";
-}
-
 export function matrixMarkdown(backend: string, rows: Row[]): string {
+  const failed = rows.some((r) => CHATS.some((c) => r.cells[c].status === "fail"));
   const lines = [
-    `${matrixStatus(rows).toUpperCase()}: Cloud chat matrix, Claude, on \`${backend}\``,
+    `${failed ? "FAIL" : "PASS"}: Cloud chat matrix, Claude, on \`${backend}\``,
     "",
     "| auth | model | first | follow-up | resume | parallel | reply (send→reply) | create→reply | reply read back |",
     "|---|---|---|---|---|---|---:|---:|---|",
@@ -110,10 +104,7 @@ export function matrixMarkdown(backend: string, rows: Row[]): string {
     "",
   ];
   const notes = rows.flatMap((r) => CHATS.filter((c) => r.cells[c].status !== "pass").map((c) => `- ${r.auth} ${r.model} ${c}: ${r.cells[c].status}: ${r.cells[c].detail.replace(/\n/g, " ")}`));
-  for (const row of rows) {
-    if (row.journeyError) notes.push(`- ${row.auth} ${row.model} journey: ${row.journeyError.replace(/\n/g, " ")}`);
-  }
-  return [...lines, ...(notes.length ? ["Journey and cell details:", "", ...notes, ""] : [])].join("\n");
+  return [...lines, ...(notes.length ? ["Why each non-pass cell is what it is:", "", ...notes, ""] : [])].join("\n");
 }
 
 function argValue(flag: string, argv: string[]): string | undefined {
@@ -189,13 +180,11 @@ async function main(argv: string[]): Promise<number> {
     }
     rows.push(...authRows);
   }
-  const status = matrixStatus(rows);
   const md = matrixMarkdown(backend, rows);
-  writeFileSync(path.join(out, "matrix.json"), `${JSON.stringify({ backend, at: new Date().toISOString(), status, rows }, null, 2)}\n`);
+  writeFileSync(path.join(out, "matrix.json"), `${JSON.stringify({ backend, at: new Date().toISOString(), rows }, null, 2)}\n`);
   writeFileSync(path.join(out, "matrix.md"), md);
   console.log(md);
-  if (status === "fail") return 1;
-  return status === "skip" && !argv.includes("--plan") ? 2 : 0;
+  return rows.some((r) => CHATS.some((c) => r.cells[c].status === "fail")) ? 1 : 0;
 }
 
 if (import.meta.main) process.exit(await main(process.argv.slice(2)));
BASE_DIFF
        test "$(git hash-object "$tree/scripts/cmux-next/cloud-claude-matrix.ts")" = 644dc5ad1ac97b0dc96b54a5d79842a320e10699
        test "$(git hash-object "$tree/scripts/cmux-next/cloud-chat-matrix.ts")" = d56e83e470b4758e0a3d62a0a35fc93cff9a0454
    fi
    for matrix in claude chat; do
        if test "$matrix" = claude; then
            set -- --auth api-key --models sonnet
        else
            set -- --cells codex-chatgpt-live
        fi
        out="$tmp_dir/$rev-$matrix"
        exit_code=0
        env -u ANTHROPIC_API_KEY -u CODEX_AUTH_JSON bun "$tree/scripts/cmux-next/cloud-$matrix-matrix.ts" "$@" --out "$out" > "$tmp_dir/command.log" || exit_code=$?
        test -s "$out/matrix.md" || { cat "$tmp_dir/command.log"; exit 1; }
        echo "$rev $matrix exit=$exit_code"
        head -1 "$out/matrix.md"
        if test "$rev" = "$base"; then
            test "$exit_code" = 0
        else
            test "$exit_code" = 2
            grep -q '^SKIP:' "$out/matrix.md"
        fi
    done
done
env -u ANTHROPIC_API_KEY bun scripts/cmux-next/cloud-claude-matrix.ts --auth api-key --models sonnet --plan --out "$tmp_dir/plan" > "$tmp_dir/plan.log"
grep -q '^SKIP:' "$tmp_dir/plan/matrix.md"
echo 'plan exit=0'
