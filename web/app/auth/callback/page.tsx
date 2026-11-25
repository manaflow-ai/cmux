import type { Metadata } from "next";
import Link from "next/link";
import { getTranslations } from "next-intl/server";

export const instant = false;

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations("emailSignInCallback");
  return {
    title: t("title"),
    robots: { index: false, follow: false },
    referrer: "no-referrer",
  };
}

// The cmux iOS and macOS apps send this URL as the link in the email sign-in
// message. The apps sign in with the code typed from that email, so this page
// must never read, forward or redeem the query: redeeming it here would spend
// the code and make the app reject it.
export default async function EmailSignInCallbackPage() {
  const t = await getTranslations("emailSignInCallback");
  return (
    <main
      className="flex min-h-screen items-center justify-center bg-background px-4 py-12 text-foreground"
      data-email-sign-in-callback
    >
      <section className="w-full max-w-[340px]">
        <h1 className="text-[22px] font-semibold tracking-[-0.02em]">
          {t("title")}
        </h1>
        <p className="mt-1.5 mb-6 text-sm leading-6 text-muted">{t("body")}</p>
        <p className="mb-3 text-sm leading-6 text-muted">{t("browserPrompt")}</p>
        <Link
          className="flex h-[38px] w-full cursor-pointer items-center justify-center border border-foreground px-3 text-sm font-medium transition-opacity hover:opacity-85 active:opacity-75 focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
          href="/handler/sign-in"
        >
          {t("browserSignIn")}
        </Link>
      </section>
    </main>
  );
}
