export type PersonalProWelcomeConfig = {
  readonly enabled: string | undefined;
  readonly resendApiKey: string | undefined;
  readonly webhookSecret: string | undefined;
  readonly stripeSecretKey: string | undefined;
};

/**
 * The dedicated personal endpoint becomes the Pro mail owner only after an
 * explicit rollout flag is set and every provider it needs is configured.
 * Until then the main billing webhook remains the single delivery owner.
 */
export function personalProWelcomeOwnsDelivery(
  config: PersonalProWelcomeConfig,
): boolean {
  return config.enabled === "1" &&
    Boolean(
      config.resendApiKey &&
        config.webhookSecret &&
        config.stripeSecretKey,
    );
}
