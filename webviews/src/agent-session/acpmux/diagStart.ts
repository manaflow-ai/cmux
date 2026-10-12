// diag (to drop): when the pane's module graph starts evaluating.
((globalThis as any).__cmuxT ??= {}).modStart = performance.now(); // diag (to drop)
export {};
