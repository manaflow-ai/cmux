import { describe, expect, test } from "bun:test";
import { managedPublicationHostname, normalizePublicationEmail, organizationSlugCandidate, validOrganizationSlug } from "../services/vm-publications/managedHostnames";
import * as Effect from "effect/Effect";
import { handlePublicationCreate } from "../app/api/vm/publications/route";
import { handlePublicationUpdate } from "../app/api/vm/publications/[id]/route";
import { updatePublicationGrant } from "../services/vm-publications/grants";
import { CloudVmPublicationRepository, type CloudVmPublicationRepositoryShape } from "../services/vm-publications/repository";

describe("managed publication names", () => {
  test("keeps VM, organization, and port unambiguous in one DNS label", () => {
    expect(managedPublicationHostname("hello", "lawrence", 3000, "cmux.sh")).toBe("hello--lawrence--3000.cmux.sh");
    expect(managedPublicationHostname("hello", "lawrence", 8080, "cmux.sh")).toBe("hello--lawrence--8080.cmux.sh");
    expect(() => managedPublicationHostname("hello--3000", "lawrence", 3000, "cmux.sh")).toThrow();
    expect(() => managedPublicationHostname("hello", "Lawrence", 3000, "cmux.sh")).toThrow();
    expect(() => managedPublicationHostname("hello", "lawrence", 65536, "cmux.sh")).toThrow();
  });
  test("fits the longest generated VM slug and port within DNS limits", () => {
    const label = managedPublicationHostname("a".repeat(35), "b".repeat(19), 65535, "cmux.sh").split(".")[0];
    expect(label.length).toBe(63);
    expect(validOrganizationSlug("b".repeat(20))).toBe(false);
    expect(() => managedPublicationHostname("a".repeat(36), "b".repeat(19), 65535, "cmux.sh")).toThrow();
  });
  test("normalizes organization names once and resolves collisions without delimiters", () => {
    expect(organizationSlugCandidate("Lawrence Chen", "user-1", 0)).toBe("lawrence-chen");
    expect(organizationSlugCandidate("Démo -- Org", "team-1", 0)).toBe("demo-org");
    expect(organizationSlugCandidate("Demo", "team-1", 1)).not.toBe(organizationSlugCandidate("Demo", "team-2", 1));
    expect(validOrganizationSlug(organizationSlugCandidate("A".repeat(80), "team", 1))).toBe(true);
  });
  test("normalizes email grants without accepting missing or malformed addresses", () => {
    expect(normalizePublicationEmail(" Guest@Example.com ")).toBe("guest@example.com");
    for (const input of ["", "guest", "a@@example.com", "a b@example.com"]) expect(normalizePublicationEmail(input)).toBeNull();
  });
});

describe("publication authorization mutations", () => {
  test("requires explicit public confirmation before create or update workflows run", async () => {
    let calls = 0;
    const context = { principal: { userId: "owner", teamIds: [] }, run: async <A>(): Promise<A> => { calls++; throw new Error("unexpected workflow"); } };
    const request = (method: string) => new Request("https://cmux.com/api/vm/publications", {
      method, body: JSON.stringify({ vmId: "vm-1", port: 3000, accessMode: "public" }),
    });
    await expect(handlePublicationCreate(request("POST"), context)).rejects.toMatchObject({ reason: "public_confirmation_required" });
    await expect(handlePublicationUpdate(request("PATCH"), "publication", context)).rejects.toMatchObject({ reason: "public_confirmation_required" });
    expect(calls).toBe(0);
  });
  test("rejects malformed grant expiry instead of creating a permanent grant", async () => {
    for (const expiresAt of [42, {}, "", "not-a-date", "2020-01-01"]) {
      const result = await Effect.runPromise(Effect.either(updatePublicationGrant({
        principal: { userId: "owner", teamIds: [] }, publicationId: "publication", email: "guest@example.com", expiresAt, revoke: false,
      }).pipe(Effect.provideService(CloudVmPublicationRepository, {} as CloudVmPublicationRepositoryShape))));
      expect(result).toMatchObject({ _tag: "Left", left: { reason: "invalid_expiry" } });
    }
  });
});
