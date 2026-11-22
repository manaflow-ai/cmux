// l10n-allow-file: gallery and test fixtures (sample sites and certificates), not shipped UI.
// Sample states of the Page Info windows, shared by their gallery entries and tests.
import type { CertificateInfo, CertificateState, SiteDataState, SiteSettingsState } from "./windows";

const leaf: CertificateInfo = {
  version: 3,
  serialNumber: "0A:3F:41:9C:22:7E:51:08:B4:6D:13:90:C2:5A:E7:01",
  signatureAlgorithm: "ECDSA with SHA-256",
  subject: {
    commonName: "meet.example.com",
    organization: "Example Corp",
    summary: "CN = meet.example.com\nO = Example Corp\nL = San Francisco\nST = California\nC = US",
  },
  issuer: {
    commonName: "Example Trust ECC CA 1",
    organization: "Example Trust",
    summary: "CN = Example Trust ECC CA 1\nO = Example Trust\nC = US",
  },
  // 2026-01-15T00:00:00Z and 2027-01-14T23:59:59Z
  notBefore: 1_768_435_200_000,
  notAfter: 1_799_971_199_000,
  publicKeyAlgorithm: "Elliptic Curve Public Key",
  subjectAlternativeNames: ["meet.example.com", "*.meet.example.com"],
  sha256Fingerprint: "d273e4249cf3ff0b4b480a524d37213e95249ea80f891bdbc841426deab2f5bf",
  sha1Fingerprint: "6a1c2b8e0f3d4a5b6c7d8e9f0a1b2c3d4e5f6a7b",
  publicKeySHA256: "5c3b6f0e9d2a4b7c8e1f0a3d6b9c2e5f8a1d4b7e0c3f6a9d2b5e8c1f4a7d0b3e",
  pem: "-----BEGIN CERTIFICATE-----\nMIIB4DCCAYagAwIBAgICEjQ...\n-----END CERTIFICATE-----\n",
};

const intermediate: CertificateInfo = {
  ...leaf,
  serialNumber: "04:00:00:00:00:01:1E:44:A5:F1",
  subject: leaf.issuer,
  issuer: {
    commonName: "Example Root R1",
    organization: "Example Trust",
    summary: "CN = Example Root R1\nO = Example Trust",
  },
  subjectAlternativeNames: [],
  sha256Fingerprint: "1f0e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
};

const root: CertificateInfo = {
  ...intermediate,
  serialNumber: "01",
  subject: { organization: "Example Trust", summary: "O = Example Trust\nC = US" },
  issuer: { organization: "Example Trust", summary: "O = Example Trust\nC = US" },
  notBefore: null,
};

export const certificateChain: CertificateState = { chain: [leaf, intermediate, root] };

export const certificateFailure: CertificateState = {
  chain: [{ ...leaf, subject: { ...leaf.subject, organization: undefined } }],
  failure: "The certificate for this server expired 12 days ago.",
};

export const noCertificate: CertificateState = { chain: [] };

export const siteData: SiteDataState = {
  entries: [
    { domain: "example.com", cookieCount: 14, hasOtherData: true, isThirdParty: false },
    { domain: "cdn-example.net", cookieCount: 2, hasOtherData: false, isThirdParty: true },
    { domain: "metrics.example.org", cookieCount: 0, hasOtherData: true, isThirdParty: true },
  ],
};

export const siteSettings: SiteSettingsState = {
  site: { kind: "web", connection: "secure", displayName: "meet.example.com" },
  origin: "https://meet.example.com",
  usage: { firstPartyCookies: 14, siteCount: 3 },
  permissions: [
    { kind: "location", setting: "ask", isDefault: true, choices: ["ask", "allow", "block"] },
    { kind: "camera", setting: "allow", isDefault: false, choices: ["ask", "allow", "block"] },
    { kind: "microphone", setting: "allow", isDefault: false, choices: ["ask", "allow", "block"] },
    { kind: "notifications", setting: "block", isDefault: false, choices: ["ask", "allow", "block"] },
    { kind: "javascript", setting: "allow", isDefault: true, choices: ["allow", "block"] },
    { kind: "popups", setting: "block", isDefault: true, choices: ["allow", "block"] },
    { kind: "sound", setting: "allow", isDefault: true, choices: ["allow", "block"] },
    { kind: "usb", setting: "ask", isDefault: true, choices: ["ask", "block"] },
  ],
  canReset: true,
};
