import { describe, expect, test } from "bun:test";
import { certificateFields, generalSections, hierarchyName } from "./certificate";
import { pageInfoStrings } from "./strings";
import { certificateChain } from "./windowFixtures";

const strings = pageInfoStrings(["en"]);
const utc = { timeZone: "UTC" };
const [leaf, intermediate, root] = certificateChain.chain;

describe("certificate viewer words", () => {
  test("the General tab names the subject, issuer, validity and SHA-256 fingerprints", () => {
    const sections = generalSections(leaf!, strings, utc);
    expect(sections.map((section) => section.title)).toEqual([
      "Issued To",
      "Issued By",
      "Validity Period",
      "SHA-256 Fingerprints",
    ]);
    expect(sections[0]!.rows.map((row) => [row.label, row.value])).toEqual([
      ["Common Name (CN)", "meet.example.com"],
      ["Organization (O)", "Example Corp"],
      ["Organizational Unit (OU)", "<Not part of certificate>"],
    ]);
    expect(sections[1]!.rows[0]!.value).toBe("Example Trust ECC CA 1");
    expect(sections[2]!.rows[0]!.value).toBe("Thursday, January 15, 2026 at 12:00:00 AM UTC");
    expect(sections[3]!.monospace).toBe(true);
    expect(sections[3]!.rows.map((row) => row.value)).toEqual([leaf!.sha256Fingerprint, leaf!.publicKeySHA256]);
  });

  test("a missing date reads as not part of the certificate", () => {
    const validity = generalSections(root!, strings, utc)[2]!;
    expect(validity.rows[0]!.value).toBe("<Not part of certificate>");
  });

  test("the Details tab lists the fields in X.509 order and leaves out empty ones", () => {
    const fields = certificateFields(leaf!, strings, utc);
    expect(fields.map((field) => field.label)).toEqual([
      "Version",
      "Serial Number",
      "Certificate Signature Algorithm",
      "Issuer",
      "Not Before",
      "Not After",
      "Subject",
      "Subject Public Key Algorithm",
      "Subject Alternative Names",
      "SHA-256 Fingerprint",
      "SHA-1 Fingerprint",
    ]);
    expect(fields[0]!.value).toBe("V3");
    expect(fields[4]!.value).toBe("Jan 15, 2026, 12:00:00 AM UTC");
    expect(fields.find((field) => field.id === "san")!.value).toBe("meet.example.com\n*.meet.example.com");

    const noNames = certificateFields(intermediate!, strings, utc).map((field) => field.id);
    expect(noNames).not.toContain("san");
    expect(certificateFields(root!, strings, utc).map((field) => field.id)).not.toContain("notBefore");
  });

  test("dates follow the page's language", () => {
    const german = pageInfoStrings(["de"]);
    expect(certificateFields(leaf!, german, utc)[4]!.value).toBe("15.01.2026, 00:00:00 UTC");
    expect(generalSections(leaf!, german, utc)[0]!.title).not.toBe("Issued To");
  });

  test("the hierarchy names a certificate by CN, then O, then serial", () => {
    expect(hierarchyName(leaf!)).toBe("meet.example.com");
    expect(hierarchyName(root!)).toBe("Example Trust");
    expect(hierarchyName({ ...root!, subject: { summary: "" } })).toBe("01");
  });
});
