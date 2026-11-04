// l10n-allow-file: synthetic transcript fixture shared by the gallery and regression tests.
import type { AcpmuxActivity, AcpmuxRow } from "../model";

export function mixedToolRunFixture(): AcpmuxActivity[] {
  const command = (id: string, description: string, output: string): AcpmuxActivity => ({
    kind: "tool", text: description,
    tool: { id, title: "Bash", description, kind: "execute", status: "completed", command: `echo ${id}`, output },
  });
  const mcp = (id: string, name: string, args: unknown, output: string): AcpmuxActivity => ({
    kind: "tool", text: name,
    tool: { id, title: `mcp__repo__${name}`, kind: "execute", status: "completed", inputSummary: JSON.stringify(args), output },
  });
  return [
    command("baseline", "Check the baseline", "baseline passed\n"),
    command("tests", "Run the updated tests", "4 passed\n"),
    { kind: "tool", text: "Loaded tools", tool: {
      id: "discovery", title: "ToolSearch", status: "completed", inputSummary: '{"query":"repo"}', output: "Loaded tools",
    } },
    mcp("grep", "grep", { description: "Find the retry handler", paths: ["src/retry.ts"], pattern: "retry" },
      '{"matches":[{"path":"src/retry.ts","line":12,"text":"retry(request)"}]}'),
    mcp("waiting", "read", { description: "Read the retry context" }, "Waiting…"),
    { ...mcp("capture", "capture", { description: "Capture the repaired screen" }, "Captured the screen"), tool: {
      id: "capture", title: "mcp__repo__capture", kind: "execute", status: "completed",
      inputSummary: '{"description":"Capture the repaired screen"}', output: "Captured the screen",
      images: ['data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="640" height="240"><rect width="640" height="240" fill="#17253a"/><text x="32" y="70" fill="#eff6ff" font-size="24">Retry settings</text><rect x="32" y="110" width="576" height="80" rx="8" fill="#274365"/><text x="52" y="158" fill="#eff6ff" font-size="20">Connection restored</text></svg>')],
    } },
  ];
}

// Raw turn rows, before turnView: no synthetic foldRun flag can hide a projection regression.
export function mixedToolTurnFixture(working = false): AcpmuxRow[] {
  const at = Date.UTC(2026, 10, 4, 0, 0);
  const work: AcpmuxRow[] = [
    { id: "mixed-prompt", version: 1, kind: "user", at, text: "Inspect the retry behavior" },
    { id: "mixed-activity", version: 1, kind: "activity", at: at + 1000, items: mixedToolRunFixture() },
  ];
  return working ? work : [...work,
    { id: "mixed-answer", version: 1, kind: "assistant", at: at + 2000, text: "The retry handler recovers correctly." },
    { id: "mixed-summary", version: 1, kind: "turnSummary", at: at + 3000, status: "completed", toolCount: 6, durationMs: 3000 },
  ];
}
