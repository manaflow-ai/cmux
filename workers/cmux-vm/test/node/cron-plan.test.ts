/**
 * The cron runs the tunnel sweep wherever the VM API runs (a revoke's 200 relies on it), the VM sweep and the agent
 * reaper only where one Worker owns the environment (src/cron-plan.ts), and every deployed environment has the cron.
 */
import { expect, it } from "vitest";
import wranglerText from "../../wrangler.jsonc?raw";
import { cronPlan } from "../../src/cron-plan.ts";

/** wrangler.jsonc without its comments (strings, which hold `//` in URLs, are kept as they are). */
const stripComments = (text: string): string => {
  let out = "";
  let inString = false;
  for (let i = 0; i < text.length; i += 1) {
    const c = text[i] ?? "";
    if (inString) {
      out += c;
      if (c === "\\") {
        out += text[i + 1] ?? "";
        i += 1;
      } else if (c === '"') inString = false;
    } else if (c === '"') {
      inString = true;
      out += c;
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i += 1;
      out += "\n";
    } else if (c === "/" && text[i + 1] === "*") {
      i = text.indexOf("*/", i + 2) + 1;
    } else out += c;
  }
  return out.replace(/,(\s*[}\]])/gu, "$1");
};

it("sweeps tunnels in every deployed environment, and VMs and agent keys only in staging and production", () => {
  expect(cronPlan("production")).toEqual({ reap: true, sweepVms: true, sweepTunnels: true });
  expect(cronPlan("staging")).toEqual({ reap: true, sweepVms: true, sweepTunnels: true });
  expect(cronPlan("preview")).toEqual({ reap: false, sweepVms: false, sweepTunnels: true });
  expect(cronPlan("local")).toEqual({ reap: false, sweepVms: false, sweepTunnels: false });
  expect(cronPlan(undefined)).toEqual({ reap: false, sweepVms: false, sweepTunnels: false });
});

it("gives every environment the VM API deploys to a cron trigger", () => {
  const config: unknown = JSON.parse(stripComments(wranglerText));
  const envs = typeof config === "object" && config !== null ? Reflect.get(config, "env") : undefined;
  expect(typeof envs === "object" && envs !== null).toBe(true);
  const names = Object.keys(envs ?? {}).sort();
  expect(names).toEqual(["preview", "production", "staging"]);
  for (const name of names) {
    const crons: unknown = Reflect.get(Reflect.get(Reflect.get(envs ?? {}, name) ?? {}, "triggers") ?? {}, "crons");
    expect(Array.isArray(crons) && crons.length > 0, `${name} has a cron`).toBe(true);
    expect(cronPlan(name).sweepTunnels, `${name} sweeps tunnels`).toBe(true);
  }
});
