import type { Metadata } from "next";
import { headers } from "next/headers";
import { redirect } from "next/navigation";

import { loadMessages } from "../../../i18n/messages";
import type { Locale } from "../../../i18n/routing";
import {
  resolvePublicationAccess,
  runPublicationAuth,
  type PublicationAccessUser,
} from "../../../services/vm-publications/auth";
import { isPublicationToken } from "../../../services/vm-publications/security";
import { verifyRequest } from "../../../services/vms/auth";
import {
  PublicationAccessCard,
  type PublicationAccessMessages,
  type PublicationAccessView,
} from "./access-card";
import { publicationAccessLocale } from "./locale";

type CloudPublicationAccessPageProps = {
  readonly searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export async function generateMetadata(): Promise<Metadata> {
  const localized = await publicationAccessMessages(await headers());
  return {
    title: localized.messages.title,
    robots: { index: false, follow: false },
  };
}

/** CMUX-hosted half of the cross-domain authorization-code handoff. */
export default async function CloudPublicationAccessPage({
  searchParams,
}: CloudPublicationAccessPageProps) {
  const params = await searchParams;
  const localized = await publicationAccessMessages(await headers());
  const demo = developmentDemo(firstParam(params.demo));
  if (demo) {
    return (
      <PublicationAccessCard
        hostname="preview.example.com"
        identity={demo === "signed-in" ? "viewer@example.com" : null}
        locale={localized.locale}
        messages={localized.messages}
        signInHref="#"
        view={demo}
      />
    );
  }

  const transaction = firstParam(params.transaction) ?? "";
  const state = firstParam(params.state) ?? "";
  if (!isPublicationToken(transaction) || !isPublicationToken(state)) {
    return (
      <PublicationAccessCard
        locale={localized.locale}
        messages={localized.messages}
        view="invalid"
      />
    );
  }
  const requestHeaders = await headers();
  const user = await verifyRequest(
    new Request("https://cmux.com/cloud/access", { headers: requestHeaders }),
    { listAllTeams: true },
  );
  const viewer: PublicationAccessUser | null = user
    ? {
      userId: user.id,
      teamIds: user.teamIds,
      identity: user.primaryEmail ?? user.displayName ?? user.id,
    }
    : null;
  const resolution = await runPublicationAuth(resolvePublicationAccess({
    transaction,
    state,
    user: viewer,
  }));

  if (resolution.kind === "authorized") redirect(resolution.callbackUrl);
  if (resolution.kind === "invalid") {
    return (
      <PublicationAccessCard
        locale={localized.locale}
        messages={localized.messages}
        view="invalid"
      />
    );
  }

  const hostname = resolution.transaction.publication.hostname;
  if (resolution.kind === "signed_out") {
    return (
      <PublicationAccessCard
        hostname={hostname}
        locale={localized.locale}
        messages={localized.messages}
        signInHref={publicationSignInHref(transaction, state)}
        view="signed-out"
      />
    );
  }

  return (
    <PublicationAccessCard
      hostname={hostname}
      identity={resolution.user.identity}
      locale={localized.locale}
      messages={localized.messages}
      view="signed-in"
    />
  );
}

function publicationSignInHref(transaction: string, state: string): string {
  const access = new URL("/cloud/access", "https://cmux.com");
  access.searchParams.set("transaction", transaction);
  access.searchParams.set("state", state);
  const afterSignIn = new URL("/handler/after-sign-in", "https://cmux.com");
  afterSignIn.searchParams.set(
    "after_auth_return_to",
    `${access.pathname}${access.search}`,
  );
  const signIn = new URL("/handler/sign-in", "https://cmux.com");
  signIn.searchParams.set(
    "after_auth_return_to",
    `${afterSignIn.pathname}${afterSignIn.search}`,
  );
  return `${signIn.pathname}${signIn.search}`;
}

async function publicationAccessMessages(headersList: Headers): Promise<{
  readonly locale: Locale;
  readonly messages: PublicationAccessMessages;
}> {
  const locale = publicationAccessLocale(headersList);
  const catalog = await loadMessages(locale);
  return {
    locale,
    messages: catalog.cloudPublicationAccess as PublicationAccessMessages,
  };
}

function developmentDemo(value: string | null): PublicationAccessView | null {
  if (process.env.NODE_ENV === "production") return null;
  if (value === "signed-out") return "signed-out";
  if (value === "signed-in") return "signed-in";
  return null;
}

function firstParam(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}
