import { createSubscriptionAnalyticsHandlers, defaultSubscriptionAnalyticsDependencies } from "./handlers";

export const { GET } = createSubscriptionAnalyticsHandlers(defaultSubscriptionAnalyticsDependencies);
