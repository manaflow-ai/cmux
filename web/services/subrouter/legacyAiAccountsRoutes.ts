import { removeAccount } from "../coderouter/accounts";
import { captureCoderouterEvent } from "../coderouter/analytics";
import { listClaudeAccounts, removeClaudeAccount } from "../coderouter/claudeUpstream";
import { reportCoderouterFailure } from "../coderouter/observability";
import { listAccounts } from "../coderouter/repository";
import { resolveCoderouterControlContext } from "../coderouter/requestContext";
import { isCoderouterViewOpenRequest } from "../coderouter/viewAnalytics";
import { makeLegacyAiAccountsHandlers } from "./legacyAiAccounts";

/** `/api/subrouter/accounts` handlers wired to the CodeRouter account store. */
export const legacyAiAccountsHandlers = makeLegacyAiAccountsHandlers({
  resolve: resolveCoderouterControlContext,
  listNative: listAccounts,
  listClaude: listClaudeAccounts,
  removeNative: async ({ teamId, accountId, stackUserId, access }) =>
    await removeAccount(teamId, accountId, stackUserId, access),
  removeClaude: removeClaudeAccount,
  capture: captureCoderouterEvent,
  isViewOpen: isCoderouterViewOpenRequest,
  report: (error, operation) => reportCoderouterFailure("rds", error, { operation }),
});
