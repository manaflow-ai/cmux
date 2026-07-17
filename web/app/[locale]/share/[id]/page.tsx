import { StackProvider, StackTheme } from "@stackframe/stack";
import { getTranslations, setRequestLocale } from "next-intl/server";
import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { ShareViewer } from "./share-viewer";

export const dynamic = "force-dynamic";

const DEFAULT_SHARE_WS_BASE = "https://share.cmux.dev";

function shareSignInHref(returnPath: string): string {
  const afterSignIn = new URL("/handler/after-sign-in", "https://cmux.com");
  afterSignIn.searchParams.set("after_auth_return_to", returnPath);
  const signIn = new URL("/handler/sign-in", "https://cmux.com");
  signIn.searchParams.set(
    "after_auth_return_to",
    `${afterSignIn.pathname}${afterSignIn.search}`,
  );
  return `${signIn.pathname}${signIn.search}`;
}

export default async function SharePage({
  params,
}: {
  params: Promise<{ locale: string; id: string }>;
}) {
  const { locale, id } = await params;
  setRequestLocale(locale);
  const t = await getTranslations({ locale, namespace: "share" });

  if (!isStackConfigured()) {
    return (
      <main className="flex min-h-dvh items-center justify-center bg-neutral-950 px-4">
        <div className="max-w-md text-center">
          <h1 className="text-[15px] font-medium text-neutral-200">
            {t("unavailable.title")}
          </h1>
          <p className="mt-2 text-[13px] text-neutral-500">
            {t("unavailable.description")}
          </p>
        </div>
      </main>
    );
  }

  const app = getStackServerApp();
  const user = await app.getUser({ or: "return-null" });
  if (!user) {
    redirect(shareSignInHref(`/${locale}/share/${id}`));
  }

  const wsBase =
    process.env.NEXT_PUBLIC_CMUX_SHARE_WS_BASE?.trim() ||
    DEFAULT_SHARE_WS_BASE;

  return (
    <StackProvider app={app}>
      <StackTheme>
        <ShareViewer
          shareId={id}
          wsBase={wsBase}
          userEmail={user.primaryEmail ?? ""}
        />
      </StackTheme>
    </StackProvider>
  );
}
