const apiKey = process.env.DAYTONA_API_KEY;
const apiUrl = process.env.DAYTONA_API_URL ?? "https://app.daytona.io/api";
if (apiKey === undefined || apiKey.length === 0) throw new Error("DAYTONA_API_KEY is required");

const headers = { authorization: `Bearer ${apiKey}`, "content-type": "application/json" };
const call = async (path: string, init: RequestInit = {}): Promise<Response> => {
  const response = await fetch(new URL(path.replace(/^\/+/, ""), `${apiUrl.replace(/\/$/u, "")}/`), {
    ...init,
    headers: { ...headers, ...(init.headers ?? {}) },
  });
  if (!response.ok) throw new Error(`Daytona ${init.method ?? "GET"} ${path} returned ${response.status}`);
  return response;
};

let sandboxId: string | undefined;
try {
  const created = await call("/sandbox", { method: "POST", body: JSON.stringify({ image: "ubuntu:22.04", name: `cmux-smoke-${Date.now()}` }) });
  const sandbox = (await created.json()) as { id?: string; toolboxProxyUrl?: string };
  if (sandbox.id === undefined) throw new Error("Daytona create response did not contain an id");
  sandboxId = sandbox.id;
  const toolbox = sandbox.toolboxProxyUrl ?? (await (await call(`/sandbox/${encodeURIComponent(sandboxId)}/toolbox-proxy-url`)).json() as { url: string }).url;
  const toolboxBase = `${toolbox.replace(/\/$/u, "")}/${encodeURIComponent(sandboxId)}`;
  const toolboxCall = async (path: string, init: RequestInit = {}) => {
    const response = await fetch(`${toolboxBase}/${path.replace(/^\/+/, "")}`, { ...init, headers: { authorization: `Bearer ${apiKey}`, ...(init.headers ?? {}) } });
    if (!response.ok) throw new Error(`Daytona toolbox ${init.method ?? "GET"} ${path} returned ${response.status}`);
    return response;
  };
  const exec = await toolboxCall("process/execute", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ command: "echo ok", timeout: 30 }) });
  const execBody = (await exec.json()) as { result?: string };
  if (!execBody.result?.includes("ok")) throw new Error("Daytona smoke exec did not return ok");
  await toolboxCall("files/upload-v2?path=workspace%2Fcmux-smoke.txt", { method: "POST", body: "ok" });
  const file = await toolboxCall("files/download?path=workspace%2Fcmux-smoke.txt");
  if ((await file.text()) !== "ok") throw new Error("Daytona smoke file read did not return ok");
  await call(`/sandbox/${encodeURIComponent(sandboxId)}/stop`, { method: "POST" });
  await call(`/sandbox/${encodeURIComponent(sandboxId)}/start`, { method: "POST" });
  console.log(`Daytona smoke passed for sandbox ${sandboxId}`);
} finally {
  if (sandboxId !== undefined) {
    await call(`/sandbox/${encodeURIComponent(sandboxId)}`, { method: "DELETE" }).catch(() => undefined);
  }
}
