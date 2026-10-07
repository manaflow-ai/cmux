// Q17: scoped keys / sub-accounts. What does the API offer?
// 1) Read the live public OpenAPI: every security scheme and every operation
//    that mints a credential.
// 2) Identities are the only credential the API key can mint. Create one
//    identity (no grants), mint its access token, and try read-only network
//    calls with that token. Then delete the identity by exact id.
// Account API keys are created only through the dashboard (Stack session),
// see the CLI's `tokens` command; nothing here touches them.
import { api, createIdentity, result, withRun } from "./lib";

await withRun("Q17", async () => {
  const doc: any = await fetch("https://api.freestyle.sh/openapi.json").then((r) => r.json());
  const schemes = doc.components?.securitySchemes ?? {};
  const minting = Object.entries(doc.paths).flatMap(([path, v]: any) =>
    Object.entries(v)
      .filter(([, o]: any) => /token|key|identit|permission/i.test(o.operationId ?? ""))
      .map(([m, o]: any) => `${m.toUpperCase()} ${path} ${o.operationId}`),
  );
  const permKinds = Object.keys(doc.paths).filter((p) => p.includes("/permissions/")).map((p) => p.split("/permissions/")[1].split("/")[0]);
  const id = await createIdentity("q17");
  const tok = await api("POST", `/v5/identities/${id.id}/tokens`, {});
  const token = tok.json.token ?? tok.json.accessToken ?? tok.json.value;
  const tries: Record<string, string> = {};
  for (const path of ["/v5/vpcs?limit=1", "/v5/tunnels?limit=1", "/v5/firewall/rules?limit=1", "/v5/vms?limit=1"]) {
    const r = await api("GET", path, undefined, { key: token, allow: [400, 401, 403, 404] });
    tries[path] = `${r.status}${r.status >= 400 ? " " + r.text.slice(0, 80) : ""}`;
  }
  result("Q17", {
    securitySchemes: Object.keys(schemes),
    credentialOperations: minting,
    identityPermissionKinds: [...new Set(permKinds)],
    identityTokenOnNetworkApi: tries,
    tokenFields: Object.keys(tok.json ?? {}),
  });
});
