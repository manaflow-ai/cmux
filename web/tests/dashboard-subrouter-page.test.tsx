import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import enMessages from "../messages/en.json";

const authorizationFailure = new Error("Stack authorization deadline exceeded");

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
  usePathname: () => "/dashboard/subrouter",
  useRouter: () => ({}),
  getPathname: () => "/dashboard/subrouter",
}));

mock.module("../app/lib/stack", () => ({
  isStackConfigured: () => true,
}));

mock.module("../services/vms/auth", () => ({
  withSubrouterAuthorizationDeadline: async () => {
    throw authorizationFailure;
  },
  verifySubrouterRequest: async () => null,
  isSubrouterAuthorizationError: (error: unknown) =>
    error === authorizationFailure,
}));

mock.module("../services/subrouter/routeHelpers", () => ({
  authorizedSubrouterTeams: async () => [],
}));

mock.module("../services/subrouter/client", () => ({
  createSubrouterClient: () => {
    throw new Error("account client must not load during auth failure");
  },
  subrouterRuntimeConfig: () => null,
}));

mock.module("../services/subrouter/tenants", () => ({
  getTenantForTeam: async () => null,
}));

mock.module("../db/client", () => ({
  cloudDb: () => {
    throw new Error("database must not load during auth failure");
  },
}));

mock.module("../app/[locale]/dashboard/components/ai-account-forms", () => ({
  AddAiAccountForms: () => null,
  DeleteAiAccountButton: () => null,
}));

const { default: SubrouterOverviewPage } = await import(
  "../app/[locale]/dashboard/subrouter/page"
);

describe("Subrouter dashboard", () => {
  test("renders recovery UI when Stack authorization is unavailable", async () => {
    const page = await SubrouterOverviewPage({
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
