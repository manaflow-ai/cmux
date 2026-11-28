// A local stand-in for Apple's App Store signing chain: a test root CA, an
// intermediate and a leaf carrying the Apple marker extensions the official
// verifier requires, and an ES256 signer that puts the chain in `x5c`.
// Never talks to Apple.

import { generateKeyPairSync } from "node:crypto";
import jsrsasign from "jsrsasign";
import jwt from "jsonwebtoken";

const APPLE_INTERMEDIATE_MARKER = "1.2.840.113635.100.6.2.1";
const APPLE_LEAF_MARKER = "1.2.840.113635.100.6.11.1";

type KeyPair = { readonly publicPem: string; readonly privatePem: string };

function keyPair(): KeyPair {
  const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  return {
    publicPem: publicKey.export({ type: "spki", format: "pem" }).toString(),
    privatePem: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
  };
}

function certificate(input: {
  readonly subject: string;
  readonly issuer: string;
  readonly publicPem: string;
  readonly signerPem: string;
  readonly ca: boolean;
  readonly marker?: string;
  readonly serial: number;
}): Buffer {
  const ext: Record<string, unknown>[] = [{ extname: "basicConstraints", cA: input.ca }];
  if (input.marker) ext.push({ extname: input.marker, extn: "0500" });
  const params = {
    version: 3,
    serial: { int: input.serial },
    issuer: { str: input.issuer },
    subject: { str: input.subject },
    notbefore: "200101000000Z",
    notafter: "401231000000Z",
    sbjpubkey: input.publicPem,
    ext,
    sigalg: "SHA256withECDSA",
    cakey: input.signerPem,
  };
  const cert = new jsrsasign.KJUR.asn1.x509.Certificate(
    params as unknown as ConstructorParameters<typeof jsrsasign.KJUR.asn1.x509.Certificate>[0],
  );
  return Buffer.from(cert.getEncodedHex(), "hex");
}

export type AppleTestSigner = {
  readonly rootCertificate: Buffer;
  sign(payload: Record<string, unknown>): string;
};

/** A fresh chain: `rootCertificate` is the only trust anchor that verifies `sign` output. */
export function createAppleTestSigner(name = "Test"): AppleTestSigner {
  const root = keyPair();
  const intermediate = keyPair();
  const leaf = keyPair();
  const rootDer = certificate({
    subject: `/CN=${name} Root`, issuer: `/CN=${name} Root`,
    publicPem: root.publicPem, signerPem: root.privatePem, ca: true, serial: 1,
  });
  const intermediateDer = certificate({
    subject: `/CN=${name} Intermediate`, issuer: `/CN=${name} Root`,
    publicPem: intermediate.publicPem, signerPem: root.privatePem, ca: true,
    marker: APPLE_INTERMEDIATE_MARKER, serial: 2,
  });
  const leafDer = certificate({
    subject: `/CN=${name} Leaf`, issuer: `/CN=${name} Intermediate`,
    publicPem: leaf.publicPem, signerPem: intermediate.privatePem, ca: false,
    marker: APPLE_LEAF_MARKER, serial: 3,
  });
  const x5c = [leafDer, intermediateDer, rootDer].map((der) => der.toString("base64"));
  return {
    rootCertificate: rootDer,
    sign: (payload) => jwt.sign(payload, leaf.privatePem, {
      algorithm: "ES256",
      noTimestamp: true,
      header: { alg: "ES256", x5c } as jwt.JwtHeader,
    }),
  };
}
