import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import enMessages from "../messages/en.json";
import {
  createTestflightUser,
  testflightUserEligibility,
} from "./helpers/testflight-user";

let stackConfigured = true;
let currentUser: ReturnType<typeof createTestflightUser> | null = null;
let ascConfigured = true;
let status = { enrolled: false } as { enrolled: boolean; state?: string };

const getUser = mock(async () => currentUser);
const isTestflightEligible = mock(async (user: unknown) =>
  testflightUserEligibility(user) ?? false,
);
const ascFetch = mock(async (path: unknown) => {
  if (String(path).startsWith("/v1/betaTesters?")) {
    return {
      data: [
        {
          type: "betaTesters",
          id: "tester_123",
          attributes: status.state ? { state: status.state } : {},
        },
      ],
    };
  }
  if (String(path).includes("/betaGroups")) {
    return {
      data: status.enrolled
        ? [
            {
              type: "betaGroups",
              id: "3ee84bfa-10ad-4f23-a45c-f9a3b037373e",
            },
          ]
        : [],
    };
  }
  return {};
});
const captureAscError = mock(() => undefined);

mock.module("next-intl/server", () => ({
  getTranslations: async (input?: string | { namespace?: string }) =>
    translator(typeof input === "string" ? input : input?.namespace),
  setRequestLocale: () => undefined,
}));

mock.module("@/i18n/navigation", () => ({
  Link: ({ href, children, ...props }: { href: string; children: React.ReactNode }) => (
    <a href={href} {...props}>
      {children}
    </a>
  ),
  redirect: () => undefined,
  usePathname: () => "/dashboard/testflight",
  useRouter: () => ({}),
  getPathname: () => "/dashboard/testflight",
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => stackConfigured,
  stackServerApp: stackConfigured ? { getUser } : null,
}));

mock.module("../services/asc/client", () => ({
  AscApiError: class AscApiError extends Error {},
  AscConfigurationError: class AscConfigurationError extends Error {},
  AscNetworkError: class AscNetworkError extends Error {},
  ascFetch,
  isAscConfigured: () => ascConfigured,
}));

mock.module("../services/errors", () => ({
  captureAscError,
  captureBillingError: mock(() => undefined),
}));

mock.module("@/services/billing/pro", () => ({
  isTestflightEligible,
}));

const { default: DashboardTestflightPage } = await import("../app/[locale]/dashboard/testflight/page");

describe("dashboard TestFlight page", () => {
  beforeEach(() => {
    stackConfigured = true;
    currentUser = createTestflightUser();
    ascConfigured = true;
    status = { enrolled: false };
    getUser.mockClear();
    isTestflightEligible.mockClear();
    ascFetch.mockClear();
    captureAscError.mockClear();
  });

  test("renders not eligible state with pricing link", async () => {
    currentUser = createTestflightUser({ eligible: false });

    const html = await renderTestflightPage();

    expect(html).toContain("Subscription required");
    expect(html).toContain("active Pro users and members of a Team subscription");
    expect(html).toContain('href="/pricing"');
    expect(html).not.toContain("/api/testflight");
    expect(ascFetch).not.toHaveBeenCalled();
  });

  test("renders eligible not enrolled state with join form", async () => {
    const html = await renderTestflightPage();

    expect(html).toContain("Join the iOS beta");
    expect(html).toContain("Apple will send a TestFlight invite to pro@example.com");
    expect(html).toContain('action="/api/testflight"');
    expect(html).toContain('name="action" value="join"');
    expect(ascFetch).toHaveBeenCalledWith(
      "/v1/betaTesters?filter[email]=pro%40example.com&limit=1",
    );
  });

  test("renders enrolled state with status and leave form", async () => {
    status = { enrolled: true, state: "INVITED" };

    const html = await renderTestflightPage();

    expect(html).toContain("You are enrolled");
    expect(html).toContain("INVITED");
    expect(html).toContain("Access ends automatically if your subscription lapses.");
    expect(html).toContain('name="action" value="leave"');
  });

  for (const [testflight, message] of [
    ["joined", "Apple will email your TestFlight invite shortly."],
    ["left", "You have left the iOS TestFlight group."],
    ["error", "TestFlight could not be updated. Try again shortly."],
    ["ineligible", "An active Pro or Team subscription is required for iOS TestFlight."],
    ["needs_email", "Add a verified primary email before joining iOS TestFlight."],
    ["unavailable", "TestFlight enrollment is not available right now."],
  ] as const) {
    test(`renders ${testflight} banner`, async () => {
      const html = await renderTestflightPage({ testflight });

      expect(html).toContain(message);
    });
  }
});

async function renderTestflightPage(searchParams: Record<string, string> = {}) {
  const element = await DashboardTestflightPage({
    params: Promise.resolve({ locale: "en" }),
    searchParams: Promise.resolve(searchParams),
  });
  return renderToStaticMarkup(element);
}

function translator(namespace?: string) {
  const root = namespace ? valueAtPath(enMessages, namespace) : enMessages;
  const t = (key: string, values?: Record<string, unknown>) => {
    const message = String(valueAtPath(root, key));
    return interpolate(message, values);
  };
  t.raw = (key: string) => valueAtPath(root, key);
  t.rich = (key: string, values?: Record<string, unknown>) =>
    interpolate(String(valueAtPath(root, key)), values);
  return t;
}

function valueAtPath(root: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>((value, part) => {
    if (value && typeof value === "object" && part in value) {
      return (value as Record<string, unknown>)[part];
    }
    return path;
  }, root);
}

function interpolate(message: string, values?: Record<string, unknown>) {
  if (!values) return message;
  return Object.entries(values).reduce(
    (result, [key, value]) => result.replaceAll(`{${key}}`, String(value)),
    message,
  );
}
