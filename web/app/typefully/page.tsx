import { redirect } from "next/navigation";
import Link from "next/link";
import {
  ALLOWED_TYPEFULLY_DOMAINS,
  requireTypefullyUserFromCookies,
  type TypefullyAccessDeniedReason,
} from "../../services/typefully/auth";
import {
  listTypefullyDrafts,
  runTypefullyWorkflow,
} from "../../services/typefully/workflows";
import { TypefullyApp } from "./typefully-app";

export const dynamic = "force-dynamic";

const SIGN_IN_PATH = `/handler/sign-in?after_auth_return_to=${encodeURIComponent("/typefully")}`;

export default async function TypefullyPage() {
  const access = await requireTypefullyUserFromCookies();
  if (!access.ok) {
    if (access.reason === "unauthenticated") {
      redirect(SIGN_IN_PATH);
    }
    return <AccessDenied reason={access.reason} email={access.email} />;
  }

  const drafts = await runTypefullyWorkflow(listTypefullyDrafts(access.user.id));

  return (
    <TypefullyApp
      initialDrafts={drafts}
      userEmail={access.user.email}
      signOutHref="/handler/sign-out"
    />
  );
}

function AccessDenied({
  reason,
  email,
}: {
  reason: TypefullyAccessDeniedReason;
  email?: string | null;
}) {
  return (
    <main className="min-h-screen bg-[#f6f7f8] px-6 py-10 text-[#191a1d]">
      <div className="mx-auto flex min-h-[calc(100vh-5rem)] w-full max-w-xl flex-col justify-center">
        <div className="border border-[#d9dde3] bg-white p-6 shadow-sm">
          <p className="mb-2 text-xs font-medium uppercase text-[#69707d]">
            Manaflow Drafts
          </p>
          <h1 className="text-2xl font-semibold tracking-tight">
            Access blocked
          </h1>
          <p className="mt-3 text-sm leading-6 text-[#4f5663]">
            {accessDeniedMessage(reason, email)}
          </p>
          <div className="mt-6 flex flex-wrap gap-2">
            <a
              href={SIGN_IN_PATH}
              className="inline-flex h-9 items-center border border-[#191a1d] bg-[#191a1d] px-3 text-sm font-medium text-white"
            >
              Sign in with Google
            </a>
            <Link
              href="/handler/sign-out"
              className="inline-flex h-9 items-center border border-[#d9dde3] bg-white px-3 text-sm font-medium text-[#191a1d]"
            >
              Sign out
            </Link>
          </div>
        </div>
      </div>
    </main>
  );
}

function accessDeniedMessage(
  reason: TypefullyAccessDeniedReason,
  email?: string | null,
): string {
  switch (reason) {
    case "auth_not_configured":
      return "Authentication is not configured for this deployment.";
    case "email_missing":
      return "Your account does not have a primary email address.";
    case "email_unverified":
      return `${email ?? "Your email"} is not verified.`;
    case "domain_not_allowed":
      return `${email ?? "Your email"} is not allowed. Use ${ALLOWED_TYPEFULLY_DOMAINS.join(", ")}.`;
    case "google_required":
      return "This workspace only allows Google sign-in.";
    case "unauthenticated":
      return "Sign in with Google to continue.";
  }
}
