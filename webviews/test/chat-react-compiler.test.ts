// Exercise the compiler used by the shipped pane, including its diagnostics. Existing
// Markdown and header bailouts are bounded here so new chat code cannot add more.
import { expect, test } from "bun:test";
import path from "node:path";
import { reactCompilerPlugin } from "../scripts/agent-pane/reactCompilerPlugin.mjs";

const srcRoot = path.resolve(import.meta.dir, "../src");
const files = [
  ["conversation/Markdown.tsx", "(BuildHIR::lowerExpression) Handle ??= operators in AssignmentExpression", 2],
  ["conversation/RenderBridgeContext.ts", "", 0],
  ["conversation/RenderCard.tsx", "", 0],
  ["conversation/useRenderRequests.ts", "", 0],
  ["header/ChatHeaderTools.tsx", "Cannot access refs during render", 3],
  ["header/ThreadTitle.tsx", "", 0],
] as const;

for (const [file, inheritedReason, inheritedCount] of files) {
  test(`chat compiler adds no bailouts in ${file}`, async () => {
    const diagnostics: { reason: string }[] = [];
    let compiled = 0;
    let load: (args: { path: string }) => Promise<unknown>;
    reactCompilerPlugin({
      mode: "babel",
      srcRoot,
      onCompiled: () => compiled++,
      onDiagnostic: (diagnostic: { reason: string }) => diagnostics.push(diagnostic),
    }).setup({
      onLoad(_options: unknown, callback: typeof load) {
        load = callback;
      },
    });
    await load!({ path: path.join(srcRoot, "agent-session/acpmux", file) });
    expect(diagnostics.filter(({ reason }) => reason !== inheritedReason)).toEqual([]);
    expect(diagnostics.length).toBeLessThanOrEqual(inheritedCount);
    expect(compiled).toBeGreaterThan(0);
  });
}
