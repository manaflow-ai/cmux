import { createDoubleBillingHandlers, defaultDoubleBillingRouteDependencies } from "./handlers";

export const { GET } = createDoubleBillingHandlers(defaultDoubleBillingRouteDependencies);
