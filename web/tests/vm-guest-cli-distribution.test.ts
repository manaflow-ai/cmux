import { describe, test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { guestCliDistributionCommand } from "../services/vms/guestCliDistribution";
const hash = (bytes: Buffer | string) => createHash("sha256").update(bytes).digest("hex");
describe("Cloud CLI distribution", () => {
  test("installs pinned engines, repairs damage, and keeps every alias on one facade", () => {
    const root = mkdtempSync(join(tmpdir(), "cloud-cli-distribution-"));
    try {
      const source = join(root,"source"); mkdirSync(source);
      const facade = "#!/bin/sh\nprintf 'facade\\n'\n", core = "#!/bin/sh\nprintf 'core\\n'\n";
      writeFileSync(join(source,"cmux-cloud-cli"),facade);writeFileSync(join(source,"coderouter"),core);
      const archive=join(root,"cli.tar.gz");
      expect(spawnSync("tar",["-czf",archive,"-C",source,"cmux-cloud-cli","coderouter"], {env:{...process.env,COPYFILE_DISABLE:"1"}}).status).toBe(0);
      const manifest={url:pathToFileURL(archive).href,archiveSha256:hash(readFileSync(archive)),binaries:{"cmux-cloud-cli":hash(facade),coderouter:hash(core)}};
      const lib=join(root,"libexec"),bin=join(root,"bin");
      const run=(verify=false)=>spawnSync("sh",["-c",guestCliDistributionCommand(verify,manifest,lib,bin)],{encoding:"utf8"});
      expect(run(true).status).toBe(1);
      const installed=run();expect(installed.stderr).toBe("");expect(installed.status).toBe(0);expect(run(true).status).toBe(0);
      for (const name of ["cmux","cr","coderouter"]) {
        expect(readlinkSync(join(bin,name))).toBe(readlinkSync(join(bin,"cmux")));
        expect(spawnSync(join(bin,name),[],{encoding:"utf8"}).stdout).toBe("facade\n");
      }
      writeFileSync(readlinkSync(join(lib,"cmux-coderouter")),"corrupt");
      expect(run(true).status).toBe(1);expect(run().status).toBe(0);expect(run(true).status).toBe(0);
      const rejected=spawnSync("sh",["-c",guestCliDistributionCommand(false,{...manifest,archiveSha256:"0".repeat(64)},lib,bin)],{encoding:"utf8"});
      expect(rejected.status).not.toBe(0);expect(rejected.stderr).toContain("checksum mismatch");expect(run(true).status).toBe(0);
    } finally { rmSync(root,{recursive:true,force:true}); }
  }, 30_000);
});
