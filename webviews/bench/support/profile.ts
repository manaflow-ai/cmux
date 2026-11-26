/// A CDP sampling profile and the function-level report shared by pane benches.
export type CpuProfile = {
  nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number }; children?: number[] }[];
  samples?: number[];
  timeDeltas?: number[];
};

/// Prints the functions with the most self and inclusive time per second of a profiled window.
/// Inclusive time counts each pane-source frame once per sample, however deep it recurses.
export function printProfile(profile: CpuProfile, label: string, wallMs: number): void {
  if (process.env.PROFILE_DUMP) require("node:fs").writeFileSync(process.env.PROFILE_DUMP, JSON.stringify(profile));
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const self = new Map<string, number>();
  (profile.samples ?? []).forEach((id, index) => {
    const frame = byId.get(id)?.callFrame;
    if (!frame || frame.functionName === "(idle)" || frame.functionName === "(program)") return;
    const key = `${frame.functionName || "(anon)"} ${frame.url.split("/").slice(-2).join("/").split("?")[0]}:${frame.lineNumber + 1}`;
    self.set(key, (self.get(key) ?? 0) + (profile.timeDeltas?.[index + 1] ?? 0) / 1000);
  });
  const top = [...self]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 30)
    .map(([key, ms]) => `  ${((ms * 1000) / wallMs).toFixed(1).padStart(7)} ms/s  ${key}`)
    .join("\n");
  console.log(`PROFILE ${label} self:\n${top}`);

  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const inclusive = new Map<string, number>();
  (profile.samples ?? []).forEach((id, index) => {
    const ms = (profile.timeDeltas?.[index + 1] ?? 0) / 1000;
    const seen = new Set<string>();
    for (let at: number | undefined = id; at !== undefined; at = parent.get(at)) {
      const frame = byId.get(at)?.callFrame;
      if (!frame || !frame.url || frame.url.includes("/deps/") || frame.url.includes("node_modules")) continue;
      const key = `${frame.functionName || "(anon)"} ${frame.url.split("/").slice(-2).join("/").split("?")[0]}:${frame.lineNumber + 1}`;
      if (seen.has(key)) continue;
      seen.add(key);
      inclusive.set(key, (inclusive.get(key) ?? 0) + ms);
    }
  });
  const totals = [...inclusive]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 40)
    .map(([key, ms]) => `  ${((ms * 1000) / wallMs).toFixed(1).padStart(7)} ms/s  ${key}`)
    .join("\n");
  console.log(`PROFILE ${label} inclusive (pane source):\n${totals}`);
}
