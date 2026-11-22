// App Store Server API: the current, Apple-signed state of a subscription.
// Responses are JWS like everything else from Apple, so callers verify the
// returned signedTransactionInfo and signedRenewalInfo with the verifier.

import { AppStoreServerAPIClient, Environment } from "@apple/app-store-server-library";

import { appleServerApiCredentials, type SignedAppleEnvironment } from "./config";

type Env = Record<string, string | undefined>;

/** The newest signed state Apple reports for one original transaction. */
export type AppleSubscriptionStatusSnapshot = {
  /** Apple `status`: 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked. */
  readonly status: number | null;
  readonly signedTransactionInfo: string;
  readonly signedRenewalInfo: string | null;
};

export type AppleServerApi = {
  /**
   * The status entry for `originalTransactionId`, or null when Apple returns
   * none (an unknown or non-subscription transaction).
   */
  subscriptionStatus(input: {
    readonly originalTransactionId: string;
    readonly bundleId: string;
    readonly environment: SignedAppleEnvironment;
  }): Promise<AppleSubscriptionStatusSnapshot | null>;
};

/** The App Store Server API client, or null when this deployment has no key. */
export function createAppleServerApi(env: Env = process.env): AppleServerApi | null {
  const credentials = appleServerApiCredentials(env);
  if (!credentials) return null;
  const clients = new Map<string, AppStoreServerAPIClient>();
  const clientFor = (bundleId: string, environment: SignedAppleEnvironment) => {
    const key = `${environment}:${bundleId}`;
    let client = clients.get(key);
    if (!client) {
      client = new AppStoreServerAPIClient(
        credentials.privateKey,
        credentials.keyId,
        credentials.issuerId,
        bundleId,
        environment === "Production" ? Environment.PRODUCTION : Environment.SANDBOX,
      );
      clients.set(key, client);
    }
    return client;
  };
  return {
    async subscriptionStatus({ originalTransactionId, bundleId, environment }) {
      const response = await clientFor(bundleId, environment).getAllSubscriptionStatuses(originalTransactionId);
      for (const group of response.data ?? []) {
        for (const item of group.lastTransactions ?? []) {
          if (item.originalTransactionId !== originalTransactionId || !item.signedTransactionInfo) continue;
          return {
            status: typeof item.status === "number" ? item.status : null,
            signedTransactionInfo: item.signedTransactionInfo,
            signedRenewalInfo: item.signedRenewalInfo ?? null,
          };
        }
      }
      return null;
    },
  };
}

let defaultApi: AppleServerApi | null | undefined;

export function appleServerApi(): AppleServerApi | null {
  if (defaultApi === undefined) defaultApi = createAppleServerApi();
  return defaultApi;
}
