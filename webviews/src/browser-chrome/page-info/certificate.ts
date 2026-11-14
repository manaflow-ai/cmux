// The certificate viewer's words: the General tab's sections and the Details tab's fields, as the
// native viewer built them (CertificateViewerWindow.generalView, CertificateDetailsView.fields).
// Dates format in the page's language; `timeZone` is for tests.
import type { Strings } from "../../pages/shared/i18n";
import type { CertificateInfo } from "./windows";

export type CertificateField = { id: string; label: string; value: string };

export type CertificateSection = {
  id: string;
  title: string;
  rows: CertificateField[];
  /** Hex digests read in a fixed-width face. */
  monospace?: boolean;
};

export type CertificateFormatOptions = { timeZone?: string };

function formatDate(
  milliseconds: number | null,
  strings: Strings,
  dateStyle: "full" | "medium",
  options: CertificateFormatOptions,
): string | undefined {
  if (milliseconds === null) return undefined;
  return new Intl.DateTimeFormat(strings.language, {
    dateStyle,
    timeStyle: "long",
    ...(options.timeZone ? { timeZone: options.timeZone } : {}),
  }).format(new Date(milliseconds));
}

/** The name a certificate goes by in the hierarchy: its CN, else its O, else its serial number. */
export function hierarchyName(certificate: CertificateInfo): string {
  return certificate.subject.commonName || certificate.subject.organization || certificate.serialNumber;
}

/** The General tab: Issued To, Issued By, Validity Period and SHA-256 Fingerprints. A field the
 * certificate lacks reads "<Not part of certificate>". */
export function generalSections(
  certificate: CertificateInfo,
  strings: Strings,
  options: CertificateFormatOptions = {},
): CertificateSection[] {
  const t = strings.t;
  const missing = t("pageInfo.viewer.notPart");
  const value = (text: string | undefined) => (text ? text : missing);
  const name = (id: string, entity: CertificateInfo["subject"]): CertificateField[] => [
    { id: `${id}.cn`, label: t("pageInfo.viewer.cn"), value: value(entity.commonName) },
    { id: `${id}.o`, label: t("pageInfo.viewer.o"), value: value(entity.organization) },
    { id: `${id}.ou`, label: t("pageInfo.viewer.ou"), value: value(entity.organizationalUnit) },
  ];
  return [
    { id: "issuedTo", title: t("pageInfo.viewer.issuedTo"), rows: name("issuedTo", certificate.subject) },
    { id: "issuedBy", title: t("pageInfo.viewer.issuedBy"), rows: name("issuedBy", certificate.issuer) },
    {
      id: "validity",
      title: t("pageInfo.viewer.validity"),
      rows: [
        {
          id: "issuedOn",
          label: t("pageInfo.viewer.issuedOn"),
          value: value(formatDate(certificate.notBefore, strings, "full", options)),
        },
        {
          id: "expiresOn",
          label: t("pageInfo.viewer.expiresOn"),
          value: value(formatDate(certificate.notAfter, strings, "full", options)),
        },
      ],
    },
    {
      id: "fingerprints",
      title: t("pageInfo.viewer.fingerprints"),
      monospace: true,
      rows: [
        { id: "certificate", label: t("pageInfo.viewer.certificate"), value: certificate.sha256Fingerprint },
        { id: "publicKey", label: t("pageInfo.viewer.publicKey"), value: certificate.publicKeySHA256 },
      ],
    },
  ];
}

/** The Details tab's fields of one certificate, in X.509 order; a field the certificate lacks is
 * left out. */
export function certificateFields(
  certificate: CertificateInfo,
  strings: Strings,
  options: CertificateFormatOptions = {},
): CertificateField[] {
  const t = strings.t;
  const fields: CertificateField[] = [
    { id: "version", label: t("pageInfo.viewer.version"), value: `V${certificate.version}` },
    { id: "serial", label: t("pageInfo.viewer.serial"), value: certificate.serialNumber },
    { id: "signatureAlgorithm", label: t("pageInfo.viewer.signatureAlgorithm"), value: certificate.signatureAlgorithm },
    { id: "issuer", label: t("pageInfo.viewer.issuer"), value: certificate.issuer.summary },
    {
      id: "notBefore",
      label: t("pageInfo.viewer.notBefore"),
      value: formatDate(certificate.notBefore, strings, "medium", options) ?? "",
    },
    {
      id: "notAfter",
      label: t("pageInfo.viewer.notAfter"),
      value: formatDate(certificate.notAfter, strings, "medium", options) ?? "",
    },
    { id: "subject", label: t("pageInfo.viewer.subject"), value: certificate.subject.summary },
    { id: "publicKeyAlgorithm", label: t("pageInfo.viewer.publicKeyAlgorithm"), value: certificate.publicKeyAlgorithm },
    { id: "san", label: t("pageInfo.viewer.san"), value: certificate.subjectAlternativeNames.join("\n") },
    { id: "sha256", label: t("pageInfo.viewer.sha256"), value: certificate.sha256Fingerprint },
    { id: "sha1", label: t("pageInfo.viewer.sha1"), value: certificate.sha1Fingerprint },
  ];
  return fields.filter((field) => field.value !== "");
}
