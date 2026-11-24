import { describe, expect, test } from "bun:test";
import { exportScript } from "../scripts/cmux-vm-image/qcow2-export";
import { guestShellProblems } from "../scripts/cmux-vm-image/shell-check";

describe("qcow2 export guest script (RFD 0100 step 6)", () => {
  const url = "https://acct.r2.cloudflarestorage.com/cmux-fleet-artifacts/cmux-vm-image/ci-1-1/rootfs.tar.zst?X-Amz-Signature=ab&x='q'";
  const script = exportScript(url);

  test("is plain /bin/sh", () => {
    expect(guestShellProblems(script).refused).toEqual([]);
  });

  test("tars only the root filesystem, read-only, keeping owners, xattrs and ACLs, and leaves its own output out", () => {
    expect(script).toContain("mount --bind / /mnt/cmux-rootfs-export");
    expect(script).toContain("remount,bind,ro");
    expect(script).toMatch(/tar --numeric-owner --xattrs .*--acls .*--exclude=\.\/var\/tmp\/cmux-qcow2/);
  });

  test("uploads to the presigned URL quoted as one word", () => {
    expect(script).toContain(
      `-T /var/tmp/cmux-qcow2/rootfs.tar.zst 'https://acct.r2.cloudflarestorage.com/cmux-fleet-artifacts/cmux-vm-image/ci-1-1/rootfs.tar.zst?X-Amz-Signature=ab&x='"'"'q'"'"''`,
    );
  });
});
