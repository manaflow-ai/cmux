/**
 * Minimal WebAuthn JSON bridge.
 *
 * The API speaks the same base64url-encoded JSON as `@simplewebauthn/browser`,
 * but pulling that package in would add a dependency for one screen. Browsers
 * that ship `parseRequestOptionsFromJSON` do the work natively; the manual
 * path below covers the rest.
 */

type RequestOptionsJSON = {
  challenge: string;
  rpId?: string;
  timeout?: number;
  userVerification?: UserVerificationRequirement;
  allowCredentials?: Array<{
    id: string;
    type: "public-key";
    transports?: AuthenticatorTransport[];
  }>;
};

export async function startAuthentication(
  optionsJSON: Record<string, unknown>,
): Promise<unknown> {
  const options = optionsJSON as RequestOptionsJSON;
  const publicKey = supportsNativeJSON()
    ? PublicKeyCredential.parseRequestOptionsFromJSON(
        optionsJSON as unknown as Parameters<
          typeof PublicKeyCredential.parseRequestOptionsFromJSON
        >[0],
      )
    : {
        ...options,
        challenge: base64URLToBuffer(options.challenge),
        allowCredentials: options.allowCredentials?.map((credential) => ({
          ...credential,
          id: base64URLToBuffer(credential.id),
        })),
      };

  const credential = await navigator.credentials.get({ publicKey });
  if (!credential) throw new Error("passkey request returned no credential");
  const publicKeyCredential = credential as PublicKeyCredential;
  if (typeof publicKeyCredential.toJSON === "function") {
    return publicKeyCredential.toJSON();
  }

  const response = publicKeyCredential.response as AuthenticatorAssertionResponse;
  return {
    id: publicKeyCredential.id,
    rawId: bufferToBase64URL(publicKeyCredential.rawId),
    type: publicKeyCredential.type,
    clientExtensionResults: publicKeyCredential.getClientExtensionResults(),
    authenticatorAttachment: publicKeyCredential.authenticatorAttachment,
    response: {
      clientDataJSON: bufferToBase64URL(response.clientDataJSON),
      authenticatorData: bufferToBase64URL(response.authenticatorData),
      signature: bufferToBase64URL(response.signature),
      userHandle: response.userHandle
        ? bufferToBase64URL(response.userHandle)
        : undefined,
    },
  };
}

function supportsNativeJSON(): boolean {
  return (
    typeof PublicKeyCredential !== "undefined" &&
    typeof PublicKeyCredential.parseRequestOptionsFromJSON === "function"
  );
}

function base64URLToBuffer(value: string): ArrayBuffer {
  const padded = value.replace(/-/gu, "+").replace(/_/gu, "/");
  const binary = atob(padded.padEnd(Math.ceil(padded.length / 4) * 4, "="));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes.buffer;
}

function bufferToBase64URL(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/gu, "-")
    .replace(/\//gu, "_")
    .replace(/=+$/u, "");
}
