/** Presentation of home-core's pending link, binding and suppression state. No transport here. */
export type ChiefContactStatus = {
  state: "idle" | "waiting" | "linked" | "stopped";
  handle?: string;
};

/** Preserve home-core address/text-link.ts codes so either transport can implement this client. */
export type LinkErrorCode =
  | "link.rate_limited"
  | "link.bound_elsewhere"
  | "link.none"
  | "link.invalid"
  | "link.expired"
  | "link.wrong_account";

export interface ChiefContactClient {
  status(): Promise<ChiefContactStatus>;
  request(handle: string): Promise<ChiefContactStatus>;
  unlink(): Promise<ChiefContactStatus>;
  /** Pushes confirmation and STOP changes; no timer or polling while the sheet is open. */
  subscribe(changed: (status: ChiefContactStatus) => void): Promise<() => void>;
}

/** A permissive input check; identity, ownership and confirmation belong to the link owner. */
export function contactHandle(value: string): string | null {
  const input = value.trim();
  if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(input)) return input;
  const phone = input.replace(/[\s().-]/g, "");
  return /^\+[1-9]\d{7,14}$/.test(phone) ? phone : null;
}

export function contactError(error: unknown): string {
  switch ((error as { code?: string } | null)?.code) {
    case "link.rate_limited":
      return "rateLimited";
    case "link.bound_elsewhere":
      return "boundElsewhere";
    case "link.expired":
    case "link.none":
      return "expired";
    case "link.invalid":
      return "invalidLink";
    case "link.wrong_account":
      return "wrongAccount";
    default:
      return "failed";
  }
}
