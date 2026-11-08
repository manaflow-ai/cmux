// Chrome's HTTPS-Upgrades fallback for typed addresses (HTTPSUpgradeFallback.swift): a scheme-less
// address loaded over https that cannot connect loads once over http. Explicit `https://` and
// pages that connected stay; a host that does not resolve does not fall back.
import { formatURL, parseURL } from "./url-display";

/** A load failure an engine reported (`BrowserLoadError`). */
export interface BrowserLoadError {
  domain: string;
  code: number;
  message: string;
  failingURL?: string | null;
  engineShowsPage?: boolean;
}

/** What the fallback reads of the tab. */
export interface BrowserLoadState {
  loadError: BrowserLoadError | null;
  isLoading: boolean;
}

export const NSURL_ERROR_DOMAIN = "NSURLErrorDomain";
export const CHROMIUM_NET_ERROR_DOMAIN = "net";

export const NSURLError = {
  timedOut: -1001,
  cannotFindHost: -1003,
  cannotConnectToHost: -1004,
  networkConnectionLost: -1005,
  badServerResponse: -1011,
  secureConnectionFailed: -1200,
  serverCertificateHasBadDate: -1201,
  serverCertificateUntrusted: -1202,
  serverCertificateHasUnknownRoot: -1203,
  serverCertificateNotYetValid: -1204,
  clientCertificateRejected: -1205,
  clientCertificateRequired: -1206,
} as const;

const isChromiumCertificateCode = (code: number): boolean => code >= -299 && code <= -200;

/** A TLS certificate the system does not trust. */
export function isCertificateError(error: BrowserLoadError): boolean {
  if (error.domain === CHROMIUM_NET_ERROR_DOMAIN) return isChromiumCertificateCode(error.code);
  return error.domain === NSURL_ERROR_DOMAIN && CERTIFICATE_CODES.has(error.code);
}

const CERTIFICATE_CODES = new Set<number>([
  NSURLError.serverCertificateUntrusted,
  NSURLError.serverCertificateHasBadDate,
  NSURLError.serverCertificateHasUnknownRoot,
  NSURLError.serverCertificateNotYetValid,
]);

const CONNECTION_CODES = new Set<number>([
  NSURLError.cannotConnectToHost,
  NSURLError.networkConnectionLost,
  NSURLError.timedOut,
  NSURLError.secureConnectionFailed,
  NSURLError.clientCertificateRejected,
  NSURLError.clientCertificateRequired,
  NSURLError.badServerResponse,
]);

function errorsEqual(a: BrowserLoadError | null, b: BrowserLoadError | null): boolean {
  if (a == null || b == null) return a == null && b == null;
  return (
    a.domain === b.domain &&
    a.code === b.code &&
    a.message === b.message &&
    (a.failingURL ?? null) === (b.failingURL ?? null) &&
    (a.engineShowsPage ?? false) === (b.engineShowsPage ?? false)
  );
}

const trimSlash = (path: string): string => (path.endsWith("/") ? path.slice(0, -1) : path);

function sameAddress(lhs: string, rhs: string): boolean {
  const a = parseURL(lhs);
  const b = parseURL(rhs);
  if (!a || !b) return false;
  return (
    (a.host?.toLowerCase() ?? null) === (b.host?.toLowerCase() ?? null) &&
    a.port === b.port &&
    trimSlash(a.path) === trimSlash(b.path)
  );
}

export class HTTPSUpgradeFallback {
  /** The upgraded address the omnibar loaded, until it connects or fails. */
  pending: string | null = null;
  private sawLoad = false;
  private earlierError: BrowserLoadError | null = null;

  /** The omnibar loads `url`, an https upgrade of typed text; `current` is the tab's error now. */
  expect(url: string, current: BrowserLoadError | null = null): void {
    this.pending = url;
    this.sawLoad = false;
    this.earlierError = current;
  }

  cancel(): void {
    this.pending = null;
  }

  /** Only the upgraded load just noted may fall back; any other commit cancels it. */
  committed(url: string): void {
    if (this.pending !== url) this.cancel();
  }

  /** The http address to load now, when `state` reports the upgraded load failed in a way http may fix. */
  observe(state: BrowserLoadState): string | null {
    const pending = this.pending;
    if (pending == null) return null;
    const error = state.loadError;
    if (
      error &&
      (this.sawLoad || !errorsEqual(error, this.earlierError)) &&
      error.failingURL != null &&
      sameAddress(error.failingURL, pending)
    ) {
      this.pending = null;
      const parts = parseURL(pending);
      if (!HTTPSUpgradeFallback.fallsBack(error) || !parts) return null;
      return formatURL({ ...parts, scheme: "http", port: parts.port === "443" ? null : parts.port });
    }
    if (state.isLoading) {
      this.sawLoad = true;
    } else if (this.sawLoad && state.loadError == null) {
      this.pending = null;
    }
    return null;
  }

  /** Failures of the TLS connection, not of the name. */
  static fallsBack(error: BrowserLoadError): boolean {
    if (isCertificateError(error)) return true;
    switch (error.domain) {
      case NSURL_ERROR_DOMAIN:
        return CONNECTION_CODES.has(error.code);
      case CHROMIUM_NET_ERROR_DOMAIN:
        // net_error_list.h: connection errors without the name errors and being offline, and certificate errors.
        return (
          (error.code >= -199 && error.code <= -100 && ![-105, -106, -137].includes(error.code)) ||
          isChromiumCertificateCode(error.code) ||
          error.code === -7
        );
      default:
        return false;
    }
  }
}
