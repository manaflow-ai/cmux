// An email address or phone number typed into New Message's To: field or an invite sheet, as
// CmuxHomeCore's ContactAddress parses it: normalized, so two spellings of one address compare
// equal (and dedupe invites). Anything that is not clearly one address is refused.

export type ContactAddress =
  /** Lowercased and trimmed. */
  | { kind: "email"; value: string }
  /** E.164: "+" then 8 to 15 digits. */
  | { kind: "phone"; value: string };

const LOCAL = /^[\p{L}\p{N}.!#$%&'*+/=?^_`{|}~-]+$/u;
const DOMAIN = /^[\p{L}\p{N}.-]+$/u;
const PHONE_SEPARATORS = new Set([" ", "(", ")", "-", ".", "/", " "]);

/** The address `input` is, or null. A phone number without a country code takes
 * `defaultCallingCode` ("1": the US region). */
export function parseAddress(input: string, defaultCallingCode = "1"): ContactAddress | null {
  const trimmed = input.trim();
  if (!trimmed || Array.from(trimmed).length > 254) return null;
  return trimmed.includes("@") ? parseEmail(trimmed) : parsePhone(trimmed, defaultCallingCode);
}

function parseEmail(text: string): ContactAddress | null {
  const value = text.toLowerCase();
  const pieces = value.split("@");
  if (pieces.length !== 2) return null;
  const [local, domain] = pieces as [string, string];
  if (!local || Array.from(local).length > 64) return null;
  if (!domain.includes(".") || domain.startsWith(".") || domain.endsWith(".") || domain.includes("..")) return null;
  if (!LOCAL.test(local) || !DOMAIN.test(domain)) return null;
  if (local.startsWith(".") || local.endsWith(".") || local.includes("..")) return null;
  const tld = domain.split(".").pop() ?? "";
  if (Array.from(tld).length < 2 || !/^\p{L}+$/u.test(tld)) return null;
  return { kind: "email", value };
}

function parsePhone(text: string, defaultCallingCode: string): ContactAddress | null {
  let plus = false;
  let digits = "";
  let index = 0;
  for (const char of text) {
    if (char === "+") {
      if (index !== 0) return null;
      plus = true;
    } else if (char >= "0" && char <= "9") digits += char;
    else if (!PHONE_SEPARATORS.has(char)) return null;
    index++;
  }
  if (!plus) {
    if (digits.startsWith("00")) digits = digits.slice(2);
    else if (!(defaultCallingCode === "1" && digits.length === 11 && digits.startsWith("1")))
      digits = defaultCallingCode + digits;
  }
  if (digits.length < 8 || digits.length > 15 || digits.startsWith("0")) return null;
  if (defaultCallingCode === "1" && digits.startsWith("1") && digits.length !== 11) return null;
  return { kind: "phone", value: `+${digits}` };
}

export const sameAddress = (a: ContactAddress, b: ContactAddress) => a.kind === b.kind && a.value === b.value;
