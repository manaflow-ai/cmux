import { createStackMembershipWebhookHandler } from "../../../../../services/teams/membershipWebhook";
export const POST = createStackMembershipWebhookHandler({ reconcile: async () => {} });
