// `cmux ai-accounts list|upload` and the legacy dashboard. Served from the
// team's CodeRouter accounts; see services/subrouter/legacyAiAccounts.ts.
import { legacyAiAccountsHandlers } from "../../../../services/subrouter/legacyAiAccountsRoutes";

export const GET = legacyAiAccountsHandlers.GET;
export const POST = legacyAiAccountsHandlers.POST;
