import { redirect } from "next/navigation";
import { cloudDb } from "@/db/client";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import {
  normalizeVaultSessionListAgent,
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
  searchParams: Promise<{ agent?: string; q?: string; cursor?: string; before?: string }>;
}) {
  const { locale } = await params;
  const filters = await searchParams;

  if (!isStackConfigured()) {
    redirect("/");
  }
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/vault/sessions")));
  }

  const agent = normalizeVaultSessionListAgent(filters.agent ?? null);
  const page = await queryVaultSessionListPage(cloudDb(), {
    userId: user.id,
    agent: agent === "all" ? undefined : agent,
    q: filters.q,
    cursor: filters.cursor ?? filters.before ?? null,
    limit: VAULT_SESSION_LIST_PAGE_SIZE,
  });
  const serialized = serializeVaultSessionListPage(page);

  return (
    <SessionsTable
      initialAgent={agent}
      initialQuery={filters.q ?? ""}
      initialRows={serialized.sessions}
      initialNextCursor={serialized.nextCursor ?? null}
    />
  );
}
