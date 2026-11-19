// App Store Server API: the current, Apple-signed state of a subscription.
// Responses are JWS like everything else from Apple, so callers verify the
// returned signedTransactionInfo and signedRenewalInfo with the verifier.

import { APIError, APIException, AppStoreServerAPIClient, Environment } from "@apple/app-store-server-library";

import { appleServerApiCredentials, type SignedAppleEnvironment } from "./config";

type Env = Record<string, string | undefined>;

/** The newest signed state Apple reports for one original transaction. */
export type AppleSubscriptionStatusSnapshot = {
  /** Apple `status`: 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked. */
  readonly status: number | null;
  readonly signedTransactionInfo: string;
  readonly signedRenewalInfo: string | null;
};

/** One page of App Store Server Notifications history. */
export type AppleNotificationHistoryPage = {
  /** Each notification's `signedPayload`, verified by the caller like a webhook body. */
  readonly signedPayloads: readonly string[];
  readonly hasMore: boolean;
  readonly paginationToken: string | null;
};

/** Apple refused a saved pagination token (invalid, expired, or its window's start aged out); restart the window. */
export class AppleHistoryPaginationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AppleHistoryPaginationError";
  }
}

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
  /**
   * One page of Get Notification History for the window. Apple keeps 180
   * days. Throws AppleHistoryPaginationError when Apple rejects the token.
   */
  notificationHistory(input: {
    readonly bundleId: string;
    readonly environment: SignedAppleEnvironment;
    readonly startDate: Date;
    readonly endDate: Date;
    readonly paginationToken: string | null;
  }): Promise<AppleNotificationHistoryPage>;
};

function isPaginationRejection(error: unknown): boolean {
  return error instanceof APIException && (
    error.apiError === APIError.INVALID_PAGINATION_TOKEN ||
    error.apiError === APIError.PAGINATION_TOKEN_EXPIRED ||
    // A resumed window whose start fell past Apple's 180 days: start a new one.
    error.apiError === APIError.START_DATE_TOO_FAR_IN_PAST
  );
}

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
    async notificationHistory({ bundleId, environment, startDate, endDate, paginationToken }) {
      let response;
      try {
        response = await clientFor(bundleId, environment).getNotificationHistory(paginationToken, {
          startDate: startDate.getTime(),
          endDate: endDate.getTime(),
        });
      } catch (error) {
        if (isPaginationRejection(error)) throw new AppleHistoryPaginationError("Apple rejected the notification history pagination token");
        throw error;
      }
      const signedPayloads = (response.notificationHistory ?? [])
        .map((item) => item.signedPayload)
        .filter((payload): payload is string => typeof payload === "string" && payload.length > 0);
      return {
        signedPayloads,
        hasMore: response.hasMore === true,
        paginationToken: response.paginationToken ?? null,
      };
    },
  };
}

let defaultApi: AppleServerApi | null | undefined;

export function appleServerApi(): AppleServerApi | null {
  if (defaultApi === undefined) defaultApi = createAppleServerApi();
  return defaultApi;
}
