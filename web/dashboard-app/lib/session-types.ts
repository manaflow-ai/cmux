import type { DashboardSession } from "@/orpc/server/dashboard/account";

/** Output of `dashboard.account.session`, inferred from the procedure's schema. */
export type DashboardSessionResponse = DashboardSession;
export type DashboardSessionUser = DashboardSession["user"];
