import { afterEach, describe, expect, test as bunTest } from "bun:test";

// Every run shells out once per catalog Price (nine, including the
// grandfathered ones) through a mock curl, so the 5s default is too tight
// on a loaded machine.
const PROVISION_TEST_TIMEOUT_MS = 30_000;
const test = (name: string, fn: () => Promise<void>) =>
  bunTest(name, fn, PROVISION_TEST_TIMEOUT_MS);
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type CurlCall = {
  args: string[];
  authorization: string;
};

type ProvisionResult = {
  calls: CurlCall[];
  exitCode: number;
  root: string;
  stderr: string;
  stdout: string;
};

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const provisionScript = resolve(
  webRoot,
  "scripts/stripe/provision-catalog.sh",
);
const temporaryRoots: string[] = [];

afterEach(() => {
  for (const root of temporaryRoots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

describe("Stripe catalog provisioning", () => {
  test("sends credentials through stdin instead of process arguments", async () => {
    const result = await runProvision("test", "valid");

    expect(result.exitCode).toBe(0);
    expect(result.calls.length).toBeGreaterThan(0);
    for (const call of result.calls) {
      expect(call.args.join("\n")).not.toContain("sk_test_mock_secret");
      expect(call.authorization).toBe(
        "Authorization: Bearer sk_test_mock_secret",
      );
    }
  });

  test("does not reuse an unrelated product with the expected name", async () => {
    const result = await runProvision("test", "unrelated-product");

    expect(result.exitCode).toBe(0);
    const priceCreation = result.calls.find(
      (call) =>
        call.args.includes("https://api.stripe.com/v1/prices") &&
        call.args.includes("product=prod_new_pro"),
    );
    expect(priceCreation).toBeDefined();
    expect(
      result.calls.some((call) => call.args.includes("product=prod_attacker")),
    ).toBe(false);
    expect(
      result.calls.some(
        (call) =>
          call.args.includes("https://api.stripe.com/v1/prices") &&
          call.args.includes("POST") &&
          call.args.includes("lookup_key=cmux-pro-yearly-480") &&
          call.args.includes("unit_amount=48000"),
      ),
    ).toBe(true);
    expect(
      result.calls.some(
        (call) =>
          call.args.includes("https://api.stripe.com/v1/prices") &&
          call.args.includes("POST") &&
          call.args.includes("lookup_key=cmux-team-yearly-576") &&
          call.args.includes("unit_amount=57600"),
      ),
    ).toBe(true);
  });

  test("finds a canonical product on a later product-search page", async () => {
    const result = await runProvision("test", "canonical-product-second-page");

    expect(result.exitCode).toBe(0);
    expect(
      result.calls.some((call) => call.args.includes("page=page_two")),
    ).toBe(true);
    expect(
      result.calls.some(
        (call) =>
          call.args.includes("https://api.stripe.com/v1/products") &&
          call.args.includes("POST") &&
          call.args.includes("name=cmux Pro"),
      ),
    ).toBe(false);
    expect(
      result.calls.some((call) => call.args.includes("product=prod_pro")),
    ).toBe(true);
  });

  test("rejects a canonical product with mismatched catalog metadata", async () => {
    const result = await runProvision("test", "wrong-product-metadata");

    expect(result.exitCode).toBe(1);
    expect(result.stderr).toContain(
      "belongs to an unexpected product: prod_pro",
    );
  });

  test("rejects a recurring price with a non-monthly cadence count", async () => {
    const result = await runProvision("test", "wrong-interval-count");

    expect(result.exitCode).toBe(1);
    expect(result.stderr).toContain(
      "cmux-pro-monthly exists with unexpected configuration",
    );
  });

  test("rejects duplicate live webhooks before mutating either endpoint", async () => {
    const result = await runProvision("live", "duplicate-webhooks");

    expect(result.exitCode).toBe(1);
    expect(result.stderr).toContain(
      "Multiple enabled webhook endpoints found",
    );
    expect(
      result.calls.some((call) =>
        call.args.includes("POST") &&
        call.args.some((argument) =>
          argument.startsWith(
            "https://api.stripe.com/v1/webhook_endpoints",
          ),
        ),
      ),
    ).toBe(false);
  });

  test("finds an existing webhook on a later list page", async () => {
    const result = await runProvision("live", "webhook-second-page");

    expect(result.exitCode).toBe(0);
    expect(
      result.calls.some((call) => call.args.includes("starting_after=we_other")),
    ).toBe(true);
    expect(
      result.calls.some((call) =>
        call.args.includes(
          "https://api.stripe.com/v1/webhook_endpoints/we_existing",
        ) && call.args.includes("POST"),
      ),
    ).toBe(true);
    expect(
      result.calls.some(
        (call) =>
          call.args.includes("https://api.stripe.com/v1/webhook_endpoints") &&
          call.args.includes("POST"),
      ),
    ).toBe(false);
  });

  test("stores a new webhook secret in a unique mode-600 file", async () => {
    const result = await runProvision("live", "create-webhook");

    expect(result.exitCode).toBe(0);
    const match = result.stdout.match(
      /Captured new webhook signing secret in (.+) \(chmod 600\)\./,
    );
    const secretPath = match?.[1];
    expect(secretPath).toBeDefined();
    expect(secretPath?.startsWith(`${join(result.root, "tmp")}/`)).toBe(true);
    expect(readFileSync(secretPath!, "utf8")).toBe("whsec_mock\n");
    expect(statSync(secretPath!).mode & 0o777).toBe(0o600);
  });
});

async function runProvision(
  mode: "test" | "live",
  scenario: string,
): Promise<ProvisionResult> {
  const root = mkdtempSync(join(tmpdir(), "cmux-stripe-catalog-test-"));
  temporaryRoots.push(root);
  const home = join(root, "home");
  const bin = join(root, "bin");
  const temp = join(root, "tmp");
  const log = join(root, "curl.jsonl");
  mkdirSync(join(home, ".secrets"), { recursive: true });
  mkdirSync(bin, { recursive: true });
  mkdirSync(temp, { recursive: true });

  const keyName =
    mode === "live"
      ? "STRIPE_LIVE_PROVISION_KEY"
      : "STRIPE_TEST_PROVISION_KEY";
  const key = mode === "live"
    ? "sk_live_mock_secret"
    : "sk_test_mock_secret";
  writeFileSync(
    join(home, ".secrets", `cmux-stripe-${mode}.env`),
    `${keyName}=${key}\n`,
    { mode: 0o600 },
  );
  const curlPath = join(bin, "curl");
  writeFileSync(curlPath, mockCurlSource, { mode: 0o700 });
  chmodSync(curlPath, 0o700);

  const childProcess = spawn("/bin/bash", [provisionScript, mode], {
    env: {
      ...process.env,
      HOME: home,
      MOCK_CURL_LOG: log,
      MOCK_STRIPE_SCENARIO: scenario,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      TMPDIR: temp,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  childProcess.stdout.setEncoding("utf8");
  childProcess.stderr.setEncoding("utf8");
  let stdout = "";
  let stderr = "";
  childProcess.stdout.on("data", (chunk: string) => {
    stdout += chunk;
  });
  childProcess.stderr.on("data", (chunk: string) => {
    stderr += chunk;
  });
  const exitCode = await new Promise<number>((resolveExit, reject) => {
    childProcess.once("error", reject);
    childProcess.once("close", (code) => resolveExit(code ?? 1));
  });
  const calls = readFileSync(log, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as CurlCall);

  return { calls, exitCode, root, stderr, stdout };
}

const mockCurlSource = String.raw`#!/usr/bin/env bun
import { appendFileSync } from "node:fs";

const args = process.argv.slice(2);
const authorization = (await Bun.stdin.text()).trim();
appendFileSync(
  process.env.MOCK_CURL_LOG,
  JSON.stringify({ args, authorization }) + "\n",
);

const scenario = process.env.MOCK_STRIPE_SCENARIO;
const url = args.find((argument) =>
  argument.startsWith("https://api.stripe.com/v1"),
);
const isPost = args.includes("POST");
const valueFor = (prefix) => {
  const argument = args.find((candidate) => candidate.startsWith(prefix));
  return argument ? argument.slice(prefix.length) : null;
};
const lookupKey = valueFor("lookup_keys[]=");
const startingAfter = valueFor("starting_after=");
const searchPage = valueFor("page=");
const expandedProduct = args.includes("expand[]=data.product");
const dataValue = valueFor("name=");
const respond = (value) => {
  process.stdout.write(JSON.stringify(value));
};

const products = {
  pro: {
    id: "prod_pro",
    name: "cmux Pro",
    active: true,
    metadata: { app: "cmux", plan: "pro" },
  },
  team: {
    id: "prod_team",
    name: "cmux Team",
    active: true,
    metadata: { app: "cmux", plan: "team" },
  },
};
const prices = {
  "cmux-pro-monthly-50": {
    id: "price_pro_month_50",
    unit_amount: 5000,
    interval: "month",
    product: "pro",
  },
  "cmux-pro-yearly-480": {
    id: "price_pro_year_480",
    unit_amount: 48000,
    interval: "year",
    product: "pro",
  },
  "cmux-team-monthly-60": {
    id: "price_team_month_60",
    unit_amount: 6000,
    interval: "month",
    product: "team",
  },
  "cmux-team-yearly-576": {
    id: "price_team_year_576",
    unit_amount: 57600,
    interval: "year",
    product: "team",
  },
  "cmux-pro-monthly": {
    id: "price_pro_month",
    unit_amount: 3000,
    interval: "month",
    product: "pro",
  },
  "cmux-pro-yearly": {
    id: "price_pro_year_legacy",
    unit_amount: 24000,
    interval: "year",
    product: "pro",
  },
  "cmux-pro-yearly-288": {
    id: "price_pro_year",
    unit_amount: 28800,
    interval: "year",
    product: "pro",
  },
  "cmux-team-monthly": {
    id: "price_team_month",
    unit_amount: 3500,
    interval: "month",
    product: "team",
  },
  "cmux-team-yearly-336": {
    id: "price_team_year",
    unit_amount: 33600,
    interval: "year",
    product: "team",
  },
};

if (url.endsWith("/prices") && !isPost) {
  const price = prices[lookupKey];
  if (
    (
      scenario === "unrelated-product" &&
      (
        lookupKey?.startsWith("cmux-pro") ||
        lookupKey === "cmux-team-yearly-336" ||
        lookupKey === "cmux-team-yearly-576"
      )
    ) ||
    (
      scenario === "canonical-product-second-page" &&
      lookupKey?.startsWith("cmux-pro")
    )
  ) {
    respond({ data: [] });
  } else if (price) {
    const product = products[price.product];
    const returnedProduct =
      scenario === "wrong-product-metadata" &&
      lookupKey === "cmux-pro-monthly" &&
      expandedProduct
        ? { ...product, metadata: { app: "other", plan: "pro" } }
        : product;
    respond({
      data: [{
        id: price.id,
        unit_amount: price.unit_amount,
        currency: "usd",
        recurring: {
          interval: price.interval,
          interval_count:
            scenario === "wrong-interval-count" &&
            lookupKey === "cmux-pro-monthly" &&
            !expandedProduct
              ? 2
              : 1,
        },
        product: expandedProduct ? returnedProduct : product.id,
        active: true,
      }],
    });
  } else {
    respond({ data: [] });
  }
} else if (url.endsWith("/products/search") && !isPost) {
  const attacker = {
    id: "prod_attacker",
    name: "cmux Pro",
    active: true,
    metadata: { app: "other", plan: "pro" },
  };
  if (scenario === "canonical-product-second-page" && !searchPage) {
    respond({ data: [attacker], has_more: true, next_page: "page_two" });
  } else if (
    scenario === "canonical-product-second-page" &&
    searchPage === "page_two"
  ) {
    respond({ data: [products.pro], has_more: false });
  } else {
    respond({
      data: scenario === "unrelated-product" ? [attacker] : [],
      has_more: false,
    });
  }
} else if (url.endsWith("/products") && isPost) {
  respond({
    id: dataValue === "cmux Pro" ? "prod_new_pro" : "prod_new_team",
  });
} else if (url.endsWith("/prices") && isPost) {
  respond({ id: "price_created" });
} else if (url.endsWith("/webhook_endpoints") && !isPost) {
  if (scenario === "duplicate-webhooks") {
    respond({
      data: [
        { id: "we_one", url: "https://cmux.com/api/stripe/webhook", status: "enabled" },
        { id: "we_two", url: "https://cmux.com/api/stripe/webhook", status: "enabled" },
      ],
      has_more: false,
    });
  } else if (scenario === "webhook-second-page" && !startingAfter) {
    respond({
      data: [{ id: "we_other", url: "https://example.com/webhook", status: "enabled" }],
      has_more: true,
    });
  } else if (
    scenario === "webhook-second-page" &&
    startingAfter === "we_other"
  ) {
    respond({
      data: [{ id: "we_existing", url: "https://cmux.com/api/stripe/webhook", status: "enabled" }],
      has_more: false,
    });
  } else {
    respond({ data: [], has_more: false });
  }
} else if (url.endsWith("/webhook_endpoints") && isPost) {
  respond({ id: "we_created", secret: "whsec_mock" });
} else if (url.includes("/webhook_endpoints/") && isPost) {
  respond({ id: url.split("/").at(-1) });
} else {
  process.stderr.write("Unexpected mock Stripe request: " + args.join(" ") + "\n");
  process.exit(2);
}
`;
