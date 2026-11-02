// Search on the Passwords page folds the Turkish dotted capital İ: it lowercases to "i" plus a
// combining dot, so a plain "istanbul" query missed a sign-in whose site or username has İ.
import { expect, test } from "bun:test";
import { filterExceptions, filterPasskeys, filterPasswords } from "../src/pages/passwords/model";
import type { PasswordException, SavedPasskey, SavedPassword } from "../src/pages/passwords/types";

const password = (id: string, site: string, username: string): SavedPassword => ({
  id,
  site,
  url: `https://${site}`,
  username,
  created: null,
  last_used: null,
  times_used: 0,
  weak: false,
  reused: false,
});

test("a plain i query finds a username or site written with İ, and İ finds i", () => {
  const rows = [
    password("1", "example.com", "İstanbul"),
    password("2", "İzmir.example", "ada"),
    password("3", "x.com", "bob"),
  ];
  expect(filterPasswords(rows, "istanbul").map((row) => row.id)).toEqual(["1"]);
  expect(filterPasswords(rows, "izmir").map((row) => row.id)).toEqual(["2"]);
  expect(filterPasswords(rows, "İSTANBUL").map((row) => row.id)).toEqual(["1"]);
  expect(filterPasswords(rows, "ISTANBUL").map((row) => row.id)).toEqual(["1"]);
  expect(filterPasswords(rows, "bob").map((row) => row.id)).toEqual(["3"]);
});

test("a decomposed dotted i (i + U+0307, I + U+0307) matches in both directions", () => {
  const rows = [password("1", "example.com", "I\u0307stanbul"), password("2", "example.com", "Ankara")];
  expect(filterPasswords(rows, "İstanbul").map((row) => row.id)).toEqual(["1"]);
  expect(filterPasswords(rows, "istanbul").map((row) => row.id)).toEqual(["1"]);
  const precomposed = [password("3", "example.com", "İstanbul")];
  expect(filterPasswords(precomposed, "i\u0307stanbul").map((row) => row.id)).toEqual(["3"]);
  expect(filterPasswords(precomposed, "I\u0307STANBUL").map((row) => row.id)).toEqual(["3"]);
});

test("passkeys and exceptions fold İ the same way", () => {
  const passkeys: SavedPasskey[] = [{ id: "p", rp_id: "example.com", user_name: "İpek", user_display_name: "" }];
  const exceptions: PasswordException[] = [{ id: "e", site: "İstanbul.example" }];
  expect(filterPasskeys(passkeys, "ipek")).toHaveLength(1);
  expect(filterExceptions(exceptions, "istanbul")).toHaveLength(1);
});
