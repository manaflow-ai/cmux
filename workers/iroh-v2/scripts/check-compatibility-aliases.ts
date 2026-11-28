const expectedAccount = "0c1675e0def6de1ab3a50a4e17dc5656";
const pairs = [
  ["cmux-iroh-v2", "cmux-v2"],
  ["cmux-iroh-v2-staging", "cmux-v2-staging"],
  ["cmux-iroh-v2-development", "cmux-v2-development"],
] as const;

type Settings = { bindings: { name: string; type: string; service?: string; class_name?: string }[] };

export function assertAliasSafe(canonical: Settings, alias: Settings | null, target: string): void {
  for (const className of ["TeamControl", "UserUsage"]) {
    if (!canonical.bindings.some(binding => binding.type === "durable_object_namespace" && binding.class_name === className)) {
      throw new Error(`${target} is missing its ${className} storage binding`);
    }
  }
  if (alias !== null && (alias.bindings.length !== 1
    || alias.bindings[0]?.type !== "service"
    || alias.bindings[0]?.name !== "CANONICAL"
    || alias.bindings[0]?.service !== target)) {
    throw new Error("Old Worker is not an existing compatibility alias; rename it in place before deploying aliases");
  }
}

async function main(): Promise<void> {
  const account = process.env.CLOUDFLARE_ACCOUNT_ID;
  const token = process.env.CLOUDFLARE_API_TOKEN;
  if (account !== expectedAccount || !token) throw new Error("Expected Cloudflare account and API token are required");
  async function settings(name: string, optional = false): Promise<Settings | null> {
    const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${account}/workers/scripts/${name}/settings`, {
      headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(15_000),
    });
    if (optional && response.status === 404) return null;
    if (!response.ok) throw new Error(`Cannot verify ${name}: HTTP ${response.status}`);
    const body = await response.json() as { success: boolean; result: Settings };
    if (!body.success || !Array.isArray(body.result?.bindings)) throw new Error(`Cannot verify ${name}: invalid settings response`);
    return body.result;
  }
  // Verify every environment before deploying any alias. Never print settings,
  // because plain-text bindings can contain private configuration.
  for (const [oldName, target] of pairs) {
    const canonical = await settings(target);
    if (!canonical) throw new Error(`Missing canonical Worker ${target}`);
    assertAliasSafe(canonical, await settings(oldName, true), target);
  }
  console.log("All compatibility targets and existing aliases verified");
}

if (import.meta.main) {
  main().catch(error => {
    console.error(`Refusing alias deployment: ${error instanceof Error ? error.message : "verification failed"}`);
    process.exitCode = 1;
  });
}
