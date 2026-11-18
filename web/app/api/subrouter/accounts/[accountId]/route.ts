// `cmux ai-accounts remove <id>`. Removes one of the team's CodeRouter
// accounts; see services/subrouter/legacyAiAccounts.ts.
import { legacyAiAccountsHandlers } from "../../../../../services/subrouter/legacyAiAccountsRoutes";

export const DELETE = legacyAiAccountsHandlers.DELETE;
