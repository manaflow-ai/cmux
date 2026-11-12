import { describe, test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readlinkSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";
import { runChild } from "./helpers/run-child";
import { guestCliDistributionCommand } from "../services/vms/guestCliDistribution";
const hash = (bytes: Buffer | string) => createHash("sha256").update(bytes).digest("hex");
describe("Cloud CLI distribution", () => {
  test("installs pinned engines, repairs damage, and keeps every alias on one facade", async () => {
    const root = mkdtempSync(join(tmpdir(), "cloud-cli-distribution-"));
    try {
      const source = join(root,"source"); mkdirSync(source);
      const facade = "#!/bin/sh\nprintf 'facade\\n'\n", core = "#!/bin/sh\nprintf 'core\\n'\n";
      writeFileSync(join(source,"cmux-cloud-cli"),facade);writeFileSync(join(source,"coderouter"),core);
      const archive=join(root,"cli.tar.gz");
      expect((await runChild("tar",["-czf",archive,"-C",source,"cmux-cloud-cli","coderouter"], {env:{...process.env,COPYFILE_DISABLE:"1"}})).status).toBe(0);
      const manifest={url:pathToFileURL(archive).href,archiveSha256:hash(readFileSync(archive)),binaries:{"cmux-cloud-cli":hash(facade),coderouter:hash(core)}};
      const lib=join(root,"libexec"),bin=join(root,"bin");
      const run=(verify=false)=>runChild("sh",["-c",guestCliDistributionCommand(verify,manifest,lib,bin)]);
      expect((await run(true)).status).toBe(1);
      const installed=await run();expect(installed.stderr).toBe("");expect(installed.status).toBe(0);expect((await run(true)).status).toBe(0);
      for (const name of ["cmux","cr","coderouter"]) {
        expect(readlinkSync(join(bin,name))).toBe(readlinkSync(join(bin,"cmux")));
        expect((await runChild(join(bin,name),[])).stdout).toBe("facade\n");
      }
      writeFileSync(readlinkSync(join(lib,"cmux-coderouter")),"corrupt");
      expect((await run(true)).status).toBe(1);expect((await run()).status).toBe(0);expect((await run(true)).status).toBe(0);
      for (let index = 0; index < 4; index += 1) {
        mkdirSync(join(lib, `cmux-cloud-${String(index).repeat(64)}`));
      }
      const activeRelease = readlinkSync(join(lib,"cmux-coderouter"));
      expect((await run()).status).toBe(0);
      const releases = readdirSync(lib).filter(name => name.startsWith("cmux-cloud-") && !name.startsWith(".cmux-"));
      expect(releases.length).toBeLessThanOrEqual(3);
      expect(releases.map(name => join(lib, name))).toContain(dirname(activeRelease));
      const rejected=await runChild("sh",["-c",guestCliDistributionCommand(false,{...manifest,archiveSha256:"0".repeat(64)},lib,bin)]);
      expect(rejected.signal).toBeNull();expect(rejected.status).not.toBe(0);expect(rejected.stderr).toContain("checksum mismatch");expect((await run(true)).status).toBe(0);
    } finally { rmSync(root,{recursive:true,force:true}); }
  }, 30_000);
});
