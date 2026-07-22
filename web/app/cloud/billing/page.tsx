import type { Metadata } from "next";
import { headers } from "next/headers";

import enMessages from "../../../messages/en.json";
import jaMessages from "../../../messages/ja.json";

type BillingReturnStatus =
  | "checkout-success"
  | "checkout-canceled"
  | "portal-return";

type BillingReturnMessageKey =
  | "checkoutSuccess"
  | "checkoutCanceled"
  | "portalReturn"
  | "default";

type CloudBillingReturnMessages = {
  eyebrow: string;
  returnTitle: string;
  returnBody: string;
  statuses: Record<BillingReturnMessageKey, { title: string; body: string }>;
};

type CloudBillingReturnPageProps = {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

const STATUS_MESSAGE_KEYS: Record<
  BillingReturnStatus,
  Exclude<BillingReturnMessageKey, "default">
> = {
  "checkout-success": "checkoutSuccess",
  "checkout-canceled": "checkoutCanceled",
  "portal-return": "portalReturn",
};

export const dynamic = "force-dynamic";

export async function generateMetadata({
  searchParams,
}: CloudBillingReturnPageProps): Promise<Metadata> {
  const params = await searchParams;
  const { messages } = cloudBillingReturnMessages(await headers());
  const statusKey = billingReturnMessageKey(firstParam(params.status));
  return {
    title: messages.statuses[statusKey].title,
    robots: { index: false, follow: false },
  };
}

export default async function CloudBillingReturnPage({
  searchParams,
}: CloudBillingReturnPageProps) {
  const params = await searchParams;
  const { locale, messages } = cloudBillingReturnMessages(await headers());
  const statusKey = billingReturnMessageKey(firstParam(params.status));
  const status = messages.statuses[statusKey];

  return (
    <main className="flex min-h-screen items-center justify-center bg-[#f6f6f3] px-5 py-12 text-[#171717]">
      <section
        className="w-full max-w-xl border border-black/10 bg-white px-6 py-8 shadow-[0_18px_60px_rgba(0,0,0,0.08)] sm:px-9 sm:py-10"
        data-billing-status={statusKey}
        lang={locale}
      >
        <p className="text-sm font-medium text-[#6b6b66]">{messages.eyebrow}</p>
        <h1 className="mt-3 text-3xl font-medium tracking-tight">{status.title}</h1>
        <p className="mt-4 text-base leading-7 text-[#555550]">{status.body}</p>

        <div className="mt-8 border-t border-black/10 pt-6">
          <h2 className="text-sm font-medium">{messages.returnTitle}</h2>
          <p className="mt-2 text-sm leading-6 text-[#555550]">{messages.returnBody}</p>
          <code className="mt-4 block w-fit bg-[#171717] px-3 py-2 font-mono text-sm text-white">
            ssh cmux.cloud
          </code>
        </div>
      </section>
    </main>
  );
}

function billingReturnMessageKey(
  status: string | null,
): BillingReturnMessageKey {
  if (status && Object.hasOwn(STATUS_MESSAGE_KEYS, status)) {
    return STATUS_MESSAGE_KEYS[status as BillingReturnStatus];
  }
  return "default";
}

function cloudBillingReturnMessages(headersList: Headers): {
  locale: "en" | "ja";
  messages: CloudBillingReturnMessages;
} {
  const locale = preferredCloudBillingLocale(
    headersList.get("accept-language") ?? "",
  );
  return {
    locale,
    messages: (locale === "ja"
      ? jaMessages.cloudBillingReturn
      : enMessages.cloudBillingReturn) as CloudBillingReturnMessages,
  };
}

function preferredCloudBillingLocale(acceptedLanguages: string): "en" | "ja" {
  const languages = acceptedLanguages
    .split(",")
    .map((part) => part.split(";")[0]?.trim().toLowerCase())
    .filter(Boolean);
  return languages.some(
    (language) => language === "ja" || language?.startsWith("ja-"),
  )
    ? "ja"
    : "en";
}

function firstParam(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}
