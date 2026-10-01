// Bakes the `mux-memory-base` Freestyle snapshot: freestyle/busybox
// (1 vCPU, 128 MiB, 1 GB; VMs boot at their snapshot's size) plus git.
// BusyBox has no libc or package manager, so git and the shared libraries it
// links against are copied from an Ubuntu VM and run through the bundled
// dynamic loader.
// Usage: FREESTYLE_API_KEY=… bun scripts/bake-memory-snapshot.ts [slug]
import { Freestyle } from "freestyle";

const slug = process.argv[2] ?? "mux-memory-base";
const freestyle = new Freestyle({ apiKey: process.env.FREESTYLE_API_KEY! });
const firewall = { rules: [] };

async function run(
  vm: {
    exec: (o: {
      command: string;
      timeoutMs?: number;
    }) => Promise<{ stdout?: string | null; stderr?: string | null; statusCode?: number | null }>;
  },
  command: string,
) {
  const result = await vm.exec({ command, timeoutMs: 120_000 });
  if (result.statusCode !== 0) throw new Error(`${command}\n${result.stderr || result.stdout}`);
  return result.stdout ?? "";
}

const donor = await freestyle.vms.create({
  snapshotId: "freestyle/ubuntu-sm",
  ttlSeconds: 1800,
  firewall,
  metadata: { mux: "bake" },
});
const box = await freestyle.vms.create({
  snapshotId: "freestyle/busybox",
  ttlSeconds: 1800,
  firewall,
  metadata: { mux: "bake" },
});
try {
  console.log("donor", donor.vmId, "box", box.vmId);
  await run(
    donor.vm,
    `set -e; rm -rf /tmp/g; mkdir -p /tmp/g/bin /tmp/g/lib; cp /usr/bin/git /tmp/g/bin/git
     for l in $(ldd /usr/bin/git | grep -o '/[^ ]*'); do cp -L "$l" /tmp/g/lib/; done
     tar czf /tmp/git.tgz -C /tmp/g .; ls -la /tmp/git.tgz`,
  );
  const archive = await donor.vm.fs.readFile("/tmp/git.tgz");
  console.log("git bundle", archive.byteLength, "bytes");
  await box.vm.fs.writeFile("/tmp/git.tgz", archive);
  const loader = (await run(donor.vm, "ls /tmp/g/lib | grep '^ld-linux'")).trim();
  await run(
    box.vm,
    `set -e; mkdir -p /opt/git; tar xzf /tmp/git.tgz -C /opt/git; rm /tmp/git.tgz
     printf '#!/bin/sh\\nexec /opt/git/lib/${loader} --library-path /opt/git/lib /opt/git/bin/git "$@"\\n' > /bin/git
     chmod +x /bin/git`,
  );
  console.log(
    await run(
      box.vm,
      `set -e; cd /tmp; rm -rf t; mkdir t; cd t; git init -q; echo a > f; git add f
       git -c user.name=mux -c user.email=mux@cmux.dev commit -qm check; git log --oneline; free -m | head -2; df -h / | tail -1
       cd /; rm -rf /tmp/t; echo "HOME=$HOME user=$(id -u)"`,
    ),
  );
  const snapshot = await box.vm.snapshot({ slug, displayName: "mux memory base (busybox + git)" });
  console.log("snapshot", JSON.stringify({ snapshotId: snapshot.snapshotId, slug }));
} finally {
  await donor.vm.delete().catch(() => undefined);
  await box.vm.delete().catch(() => undefined);
}
