import { forgetAllSessions } from "@/app/handler/account-sessions-client";
import { clearCoderouterOrganizationScope } from "@/services/coderouter/organizationScope";
import { localeHomeHref } from "./locale-href";

/**
 * The dashboard's sign-out, shared by the account menu and Settings so the
 * two can't drift: sign out, end the other accounts this browser keeps for
 * switching (like Gmail), clear the coderouter scope, and leave the SPA.
 * The saved-session cleanup runs on the way out and is never waited on, so a
 * slow cleanup can't hold up the sign-out.
 */
export async function signOutOfDashboard(app: { signOut(): Promise<void> }, locale: string): Promise<void> {
  await app.signOut();
  void forgetAllSessions({ keepalive: true });
  clearCoderouterOrganizationScope();
  // Home is outside the SPA; a document load also drops every cached query.
  window.location.assign(localeHomeHref(locale));
}
