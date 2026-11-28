import { makeStripeWebhookHandler } from "../../../../services/billing/stripeWebhook";

export { makeStripeWebhookHandler };

export const POST = makeStripeWebhookHandler();
