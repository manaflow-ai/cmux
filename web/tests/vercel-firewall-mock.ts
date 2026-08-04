import { mock } from "bun:test";

type RateLimitResult = {
  readonly rateLimited: boolean;
  readonly error: string | null;
};

export const checkRateLimit = mock(async (): Promise<RateLimitResult> => ({
  rateLimited: false,
  error: null,
}));

export function installVercelFirewallMock(): void {
  mock.module("@vercel/firewall", () => ({
    checkRateLimit,
  }));
}
