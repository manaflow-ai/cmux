import { createHmac, timingSafeEqual } from "node:crypto";

/** Worker credentials are server-side only; user bearer tokens never authorize ingestion. */
export function isRunWorkerAuthorized(request: Request, scope?: { runId: string; attemptId: string }): boolean {
  const secret = process.env.CMUX_RUN_WORKER_SECRET?.trim();
  const configured = process.env.CMUX_RUN_WORKER_TOKEN?.trim();
  const presented = request.headers.get("x-cmux-run-worker-token")?.trim();
  if (!presented) return false;
  if (secret && scope) {
    const expected = createHmac("sha256", secret).update(`${scope.runId}:${scope.attemptId}`).digest("hex");
    const left = Buffer.from(expected, "utf8");
    const right = Buffer.from(presented, "utf8");
    return left.length === right.length && timingSafeEqual(left, right);
  }
  if (!configured) return false;
  const left = Buffer.from(configured, "utf8");
  const right = Buffer.from(presented, "utf8");
  return left.length === right.length && timingSafeEqual(left, right);
}

