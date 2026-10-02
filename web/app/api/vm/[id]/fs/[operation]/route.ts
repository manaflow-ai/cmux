import {
  jsonResponse,
  resolveVmRouteAccountScope,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../../services/vms/routeHelpers";
import { runVmRoute } from "../../../../../../services/vms/routeWorkflow";
import {
  listVmFiles,
  mkdirVmFile,
  readVmFile,
  removeVmFile,
  statVmFile,
  writeVmFile,
} from "../../../../../../services/vms/workflows";

const MAX_PATH_BYTES = 4096;
const MAX_WRITE_BYTES = 16 * 1024 * 1024;
const OPERATIONS = new Set(["dir", "read", "write", "mkdir", "remove", "stat"]);

type Params = { id: string; operation: string };

function pathError(message: string): Response {
  return vmErrorResponse({ error: "vm_invalid_path", status: 400, message, action: "Pass an absolute guest path without '..'." });
}

function validatePath(raw: string | null): string | Response {
  const path = raw?.trim() ?? "";
  if (!path || !path.startsWith("/") || path.includes("\0") || path.split("/").includes("..") || Buffer.byteLength(path, "utf8") > MAX_PATH_BYTES) {
    return pathError("Cloud VM file paths must be absolute, contain no '..', and be at most 4096 bytes.");
  }
  return path;
}

export async function GET(request: Request, { params }: { params: Promise<Params> }): Promise<Response> {
  const { id, operation } = await params;
  return withAuthedVmApiRoute(request, "/api/vm/[id]/fs/[operation]", { "cmux.vm.operation": `fs_${operation}` }, "/api/vm/[id]/fs GET failed", async ({ user, span }) => {
    if (!OPERATIONS.has(operation) || !["dir", "read", "stat"].includes(operation)) return vmErrorResponse({ error: "vm_unknown_file_operation", status: 404, message: "Unknown Cloud VM file operation." });
    const path = validatePath(new URL(request.url).searchParams.get("path"));
    if (typeof path !== "string") return path;
    const account = resolveVmRouteAccountScope(user, request);
    if (!account.ok) return account.response;
    const base = { userId: user.id, billingTeamId: account.entitlements.billingTeamId, callerPlanId: account.entitlements.planId, maxActiveVms: account.entitlements.maxActiveVms, teamIds: user.teamIds, providerVmId: id };
    const run = operation === "dir"
      ? await runVmRoute(listVmFiles(base, path), { request })
      : operation === "read"
        ? await runVmRoute(readVmFile(base, path), { request })
        : await runVmRoute(statVmFile(base, path), { request });
    if (!run.ok) return run.response;
    setSpanPath(span, id, path);
    if (operation === "read") {
      const value = run.value as { path: string; data: Uint8Array; size: number };
      return jsonResponse({ path: value.path, dataBase64: Buffer.from(value.data).toString("base64"), size: value.size });
    }
    if (operation === "dir") return jsonResponse({ entries: run.value });
    return jsonResponse(run.value);
  });
}

export async function POST(request: Request, { params }: { params: Promise<Params> }): Promise<Response> {
  const { id, operation } = await params;
  return withAuthedVmApiRoute(request, "/api/vm/[id]/fs/[operation]", { "cmux.vm.operation": `fs_${operation}` }, "/api/vm/[id]/fs POST failed", async ({ user, span }) => {
    if (!["write", "mkdir"].includes(operation)) return vmErrorResponse({ error: "vm_unknown_file_operation", status: 404, message: "Unknown Cloud VM file operation." });
    let body: unknown;
    try { body = await request.json(); } catch { return vmErrorResponse({ error: "vm_invalid_json", status: 400, message: "Cloud VM file operation expected a JSON object body." }); }
    if (!body || typeof body !== "object" || Array.isArray(body)) return vmErrorResponse({ error: "vm_invalid_request", status: 400, message: "Cloud VM file operation body must be a JSON object." });
    const raw = body as { path?: unknown; dataBase64?: unknown; mode?: unknown };
    const path = validatePath(typeof raw.path === "string" ? raw.path : null);
    if (typeof path !== "string") return path;
    const account = resolveVmRouteAccountScope(user, request);
    if (!account.ok) return account.response;
    const base = { userId: user.id, billingTeamId: account.entitlements.billingTeamId, callerPlanId: account.entitlements.planId, maxActiveVms: account.entitlements.maxActiveVms, teamIds: user.teamIds, providerVmId: id };
    const run = operation === "mkdir"
      ? await runVmRoute(mkdirVmFile(base, path), { request })
      : await writeFromBody(request, base, path, raw.dataBase64, raw.mode);
    if (!run.ok) return run.response;
    setSpanPath(span, id, path);
    return jsonResponse({ ok: true, path });
  });
}

export async function DELETE(request: Request, { params }: { params: Promise<Params> }): Promise<Response> {
  const { id, operation } = await params;
  return withAuthedVmApiRoute(request, "/api/vm/[id]/fs/[operation]", { "cmux.vm.operation": `fs_${operation}` }, "/api/vm/[id]/fs DELETE failed", async ({ user, span }) => {
    if (operation !== "remove") return vmErrorResponse({ error: "vm_unknown_file_operation", status: 404, message: "Unknown Cloud VM file operation." });
    const path = validatePath(new URL(request.url).searchParams.get("path"));
    if (typeof path !== "string") return path;
    const account = resolveVmRouteAccountScope(user, request);
    if (!account.ok) return account.response;
    const run = await runVmRoute(removeVmFile({ userId: user.id, billingTeamId: account.entitlements.billingTeamId, callerPlanId: account.entitlements.planId, maxActiveVms: account.entitlements.maxActiveVms, teamIds: user.teamIds, providerVmId: id }, path), { request });
    if (!run.ok) return run.response;
    setSpanPath(span, id, path);
    return jsonResponse({ ok: true, path });
  });
}

async function writeFromBody(request: Request, base: Parameters<typeof writeVmFile>[0], path: string, rawData: unknown, rawMode: unknown) {
  if (typeof rawData !== "string") return { ok: false as const, response: vmErrorResponse({ error: "vm_invalid_file_body", status: 400, message: "Cloud file writes require dataBase64." }) };
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(rawData)) {
    return { ok: false as const, response: vmErrorResponse({ error: "vm_invalid_file_body", status: 400, message: "dataBase64 must be valid base64." }) };
  }
  const data = Buffer.from(rawData, "base64");
  if (data.length > MAX_WRITE_BYTES) return { ok: false as const, response: vmErrorResponse({ error: "vm_file_too_large", status: 413, message: "Cloud file writes are limited to 16 MiB in this route." }) };
  if (rawMode !== undefined && !(typeof rawMode === "number" && Number.isInteger(rawMode) && rawMode >= 0 && rawMode <= 0o7777)) {
    return { ok: false as const, response: vmErrorResponse({ error: "vm_invalid_file_mode", status: 400, message: "mode must be an integer from 0 through 4095." }) };
  }
  const mode = rawMode as number | undefined;
  return runVmRoute(writeVmFile(base, path, data, mode), { request });
}

function setSpanPath(span: { setAttribute: (key: string, value: string | number) => void }, id: string, path: string): void {
  span.setAttribute("cmux.vm.id", id);
  span.setAttribute("cmux.path_length", Buffer.byteLength(path, "utf8"));
}
