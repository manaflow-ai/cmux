// The Page Info windows' wire: the state each window's page draws (`cmux.<page>.state`) and the
// commands it sends (`cmux.<page>.command`), mirrors of CmuxNextBrowser's PageInfoWindowWire and
// PageInfoWindowCommand (PageInfoWire.swift). The host owns every value; nothing changes here.
import type { PageInfoSite, SitePermissionKind, SitePermissionSetting } from "./model";

/** One permission row of the Site settings window, in the engine's catalog order. */
export type SiteSettingsPermission = {
  kind: SitePermissionKind;
  setting: SitePermissionSetting;
  /** No decision stored for this origin. */
  isDefault: boolean;
  /** What its menu offers (`SitePermissionKind.choices`). */
  choices: SitePermissionSetting[];
};

/** The Site settings window (cmux-page://cmux.site-settings/). */
export type SiteSettingsState = {
  site: PageInfoSite;
  origin: string;
  /** null while the numbers load. */
  usage: { firstPartyCookies: number; siteCount: number } | null;
  permissions: SiteSettingsPermission[];
  /** Some permission differs from its default ("Reset permissions" has work). */
  canReset: boolean;
};

/** One site that stored data while the page was open (`SiteDataEntry`). */
export type SiteDataEntry = {
  domain: string;
  cookieCount: number;
  /** Local storage, IndexedDB, caches and the like. */
  hasOtherData: boolean;
  isThirdParty: boolean;
};

/** The On-device site data window (cmux-page://cmux.site-data/): this site first, null while loading. */
export type SiteDataState = { entries: SiteDataEntry[] | null };

/** A distinguished name's fields (`CertificateName`). */
export type CertificateName = {
  commonName?: string;
  organization?: string;
  organizationalUnit?: string;
  /** Every attribute, most significant first, one "CN = x" per line. */
  summary: string;
};

/** One certificate of the chain (`PageInfoCertificate`). Dates are milliseconds since 1970. */
export type CertificateInfo = {
  version: number;
  /** Colon-separated uppercase hex. */
  serialNumber: string;
  signatureAlgorithm: string;
  issuer: CertificateName;
  subject: CertificateName;
  notBefore: number | null;
  notAfter: number | null;
  publicKeyAlgorithm: string;
  subjectAlternativeNames: string[];
  /** Lowercase hex digests. */
  sha256Fingerprint: string;
  sha1Fingerprint: string;
  publicKeySHA256: string;
  pem: string;
};

/** The certificate viewer (cmux-page://cmux.certificate/): the chain leaf first. */
export type CertificateState = {
  chain: CertificateInfo[];
  /** The engine's reason verification failed. */
  failure?: string;
};

/** Everything a Page Info window can ask of its host. */
export type PageInfoWindowCommand =
  | { type: "setPermission"; kind: SitePermissionKind; setting: SitePermissionSetting }
  | { type: "resetPermissions" }
  /** One site's data; without a domain, the Site settings window's whole site. */
  | { type: "deleteSiteData"; domain?: string }
  /** Exports the chain from the certificate at `index` (0 is the leaf) to the root as PEM. */
  | { type: "exportCertificate"; index: number }
  | { type: "close" };
