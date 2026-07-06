import { redirect } from "next/navigation";
import { cloudDb } from "@/db/client";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import {
  queryVaultSessionListPage,
  serializeVaultSessionListPage,
  VAULT_SESSION_LIST_PAGE_SIZE,
} from "@/services/vault/sessionList";
import { SessionsTable } from "./sessions-table";

export const dynamic = "force-dynamic";

export default async function VaultSessionsPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ q?: string; cursor?: string; before?: string }>;
}) {
  const { locale } = await params;
  const filters = await searchParams;

  if (!isStackConfigured()) {
    redirect("/");
  }
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/vault/sessions")));
  }

  const page = await queryVaultSessionListPage(cloudDb(), {
    userId: user.id,
    q: filters.q,
    cursor: filters.cursor ?? filters.before ?? null,
    limit: VAULT_SESSION_LIST_PAGE_SIZE,
  });
  const serialized = serializeVaultSessionListPage(page);

  return (
    <SessionsTable
      initialQuery={filters.q ?? ""}
      initialRows={serialized.sessions}
      initialNextCursor={serialized.nextCursor ?? null}
    />
  );
}
