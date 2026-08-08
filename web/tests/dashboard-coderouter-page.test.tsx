import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import enMessages from "../messages/en.json";

const authorizationFailure = new Error("Stack authorization deadline exceeded");
let authorizationAvailable = false;
let authJsonAvailable = true;
let cutoverReady = true;
let hostedControlConfigured = true;
let hostedExchangeCalls = 0;

mock.module("next-intl/server", () => ({
  getTranslations: async (input?: string | { namespace?: string }) =>
    translator(typeof input === "string" ? input : input?.namespace),
  setRequestLocale: () => undefined,
}));

mock.module("next/headers", () => ({
  headers: async () => new Headers(),
}));

mock.module("next/navigation", () => ({
  redirect: (target: string) => {
    throw new Error(`unexpected redirect to ${target}`);
  },
}));

mock.module("@/i18n/navigation", () => ({
  Link: ({
    href,
    children,
    ...props
  }: {
    href: string;
    children: React.ReactNode;
  }) => <a href={href} {...props}>{children}</a>,
  redirect: () => undefined,
  usePathname: () => "/dashboard/coderouter",
  useRouter: () => ({}),
  getPathname: () => "/dashboard/coderouter",
}));

mock.module("../app/lib/stack", () => ({
  isStackConfigured: () => true,
  getStackServerApp: () => ({
    getAuthJson: async () => {
      if (!authJsonAvailable) throw new Error("Stack refresh unavailable");
      return { accessToken: "test-access-token" };
    },
  }),
}));

class TestSubrouterAuthorizationUnavailableError extends Error {}

mock.module("../services/vms/auth", () => ({
  withSubrouterAuthorizationDeadline: async (
    operation: (signal: AbortSignal) => Promise<unknown>,
  ) => {
    if (!authorizationAvailable) throw authorizationFailure;
    return await operation(new AbortController().signal);
  },
  verifySubrouterRequest: async () => ({ id: "user-1" }),
  SubrouterAuthorizationUnavailableError:
    TestSubrouterAuthorizationUnavailableError,
  isSubrouterAuthorizationError: (error: unknown) =>
    error === authorizationFailure ||
    error instanceof TestSubrouterAuthorizationUnavailableError,
}));

mock.module("../services/subrouter/routeHelpers", () => ({
  authorizedSubrouterTeams: async () => [{
    teamId: "team-1",
    teamName: "Team One",
    use: true,
    manageAccounts: true,
  }],
}));

mock.module("../services/subrouter/hostedClient", () => ({
  createHostedSubrouterClient: () => ({
    tenantControlConfigured: hostedControlConfigured,
    exchangeTeam: async () => {
      hostedExchangeCalls += 1;
      return {
        tenantId: "team-1",
        tenantKey: "srt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      };
    },
    listAccounts: async () => [],
  }),
}));

mock.module("../services/subrouter/cutover", () => ({
  hostedSubrouterCutoverReadyForTeam: async () => cutoverReady,
}));

mock.module("../db/client", () => ({
  cloudDb: () => ({}),
}));

mock.module("../app/[locale]/dashboard/components/ai-account-forms", () => ({
  AddAiAccountForms: () => null,
  DeleteAiAccountButton: () => null,
}));

const { default: CoderouterOverviewPage } = await import(
  "../app/[locale]/dashboard/coderouter/page"
);

describe("coderouter dashboard", () => {
  beforeEach(() => {
    authorizationAvailable = false;
    authJsonAvailable = true;
    cutoverReady = true;
    hostedControlConfigured = true;
    hostedExchangeCalls = 0;
  });

  test("renders recovery UI when Stack authorization is unavailable", async () => {
    const page = await CoderouterOverviewPage({
      params: Promise.resolve({ locale: "en" }),
      searchParams: Promise.resolve({}),
    });
    const html = renderToStaticMarkup(page);

    expect(html).toContain("Accounts could not load");
    expect(html).toContain(
      "The account service could not be reached. Try again shortly.",
    );
    expect(html).not.toContain("unexpected redirect");
  });

  test("keeps a legacy-mapped team off hosted accounts until migration finishes", async () => {
    authorizationAvailable = true;
    cutoverReady = false;

    const page = await CoderouterOverviewPage({
      params: Promise.resolve({ locale: "en" }),
      searchParams: Promise.resolve({}),
    });
    const html = renderToStaticMarkup(page);

    expect(hostedExchangeCalls).toBe(0);
    expect(html).toContain("Accounts temporarily unavailable");
    expect(html).toContain(
      "Shared accounts are temporarily unavailable. Try again shortly.",
    );
  });

  test("renders recovery UI when the bounded Stack session refresh fails", async () => {
    authorizationAvailable = true;
    authJsonAvailable = false;

    const page = await CoderouterOverviewPage({
      params: Promise.resolve({ locale: "en" }),
      searchParams: Promise.resolve({}),
    });
    const html = renderToStaticMarkup(page);

    expect(html).toContain("Accounts could not load");
    expect(html).toContain(
      "The account service could not be reached. Try again shortly.",
    );
    expect(hostedExchangeCalls).toBe(0);
  });

  test("renders setup guidance when hosted tenant control is not configured", async () => {
    authorizationAvailable = true;
    hostedControlConfigured = false;

    const page = await CoderouterOverviewPage({
      params: Promise.resolve({ locale: "en" }),
      searchParams: Promise.resolve({}),
    });
    const html = renderToStaticMarkup(page);

    expect(html).toContain("AI account management isn&#x27;t available yet");
    expect(hostedExchangeCalls).toBe(0);
  });
});

function translator(namespace?: string) {
  const root = namespace ? valueAtPath(enMessages, namespace) : enMessages;
  const t = (key: string, values?: Record<string, unknown>) =>
    interpolate(String(valueAtPath(root, key)), values);
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

function interpolate(
  message: string,
  values?: Record<string, unknown>,
): string {
  if (!values) return message;
  return Object.entries(values).reduce(
    (result, [key, value]) => result.replaceAll(`{${key}}`, String(value)),
    message,
  );
}
