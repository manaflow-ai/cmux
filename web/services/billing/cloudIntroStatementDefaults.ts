import { Resend } from "resend";

import { env } from "../../app/env";
import { getStackServerApp } from "../../app/lib/stack";
import { DEFAULT_PRO_FROM_EMAIL, PRO_REPLY_TO_EMAIL } from "./proFulfillment";
import { createDrizzleCloudIntroStatementStore } from "./cloudIntroStatementStore";
import type { CloudIntroStatementJobDependencies } from "./cloudIntroStatementJob";
import { createCloudPassUsageReader } from "./cloudPassUsage";
import { activeAppleEntitlementForUser } from "./apple/entitlement";
import { createDrizzleCloudIntroRenewalStore, type CloudIntroRenewalDependencies } from "./cloudIntroRenewal";
import { activePersonalPlanForUser } from "./pro";
import { resolveGoPrice, stripe } from "./stripe";

const DEFAULT_ORIGIN = "https://cmux.com";

function siteOrigin(): string {
  const configured = process.env.CMUX_APP_ORIGIN?.trim();
  if (!configured) return DEFAULT_ORIGIN;
  try {
    const url = new URL(configured);
    return url.protocol === "https:" || url.protocol === "http:" ? url.origin : DEFAULT_ORIGIN;
  } catch {
    return DEFAULT_ORIGIN;
  }
}

/** The production wiring for the statement cron: the database, the sign-in records and the site's email sender. */
export function defaultCloudIntroStatementDependencies(now = new Date()): CloudIntroStatementJobDependencies {
  return {
    env: process.env,
    now,
    store: createDrizzleCloudIntroStatementStore(),
    readUsage: createCloudPassUsageReader(),
    recipientEmail: async (stackUserId) => {
      const user = await getStackServerApp().getUser(stackUserId);
      return user?.primaryEmail?.trim() || null;
    },
    sendEmail: async (payload, options) => await new Resend(env.RESEND_API_KEY).emails.send(payload, options),
    fromEmail: env.CMUX_PRO_FROM_EMAIL ?? DEFAULT_PRO_FROM_EMAIL,
    replyTo: PRO_REPLY_TO_EMAIL,
    origin: siteOrigin(),
  };
}

/** The production wiring for the day-30 Plus charge; it does nothing unless CMUX_CLOUD_INTRO_RENEW_CHARGE=1. */
export function defaultCloudIntroRenewalDependencies(now = new Date()): CloudIntroRenewalDependencies {
  return {
    env: process.env,
    now,
    store: createDrizzleCloudIntroRenewalStore(),
    stripe,
    plusPriceId: resolveGoPrice,
    hasPersonalPlan: async (stackUserId) => {
      const [web, apple] = await Promise.all([
        activePersonalPlanForUser(stackUserId),
        activeAppleEntitlementForUser(stackUserId),
      ]);
      return web !== null || apple !== null;
    },
  };
}
