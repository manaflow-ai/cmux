// Prints what `ssh` needs to reach one Freestyle VM: a VM-scoped, temporary identity token
// carried in the SSH user name (the same way `freestyle vm ssh` does it), one value per line:
//   <identity id>\n<user:token>\n<host>
// The caller deletes the identity when it is done:  bun ssh-args.ts --delete <identity id>
import { Freestyle } from "freestyle";

const f = new Freestyle({ apiKey: process.env.FREESTYLE_API_KEY });
const [a, b] = process.argv.slice(2);
if (a === "--delete") {
  await f.identities.ref(b).delete();
  console.log("deleted " + b);
} else if (a === "--start") {
  const vm = await f.vms.get(b);
  if (vm.state !== "running") await f.vms.ref(vm.id).start();
  if (process.argv[4]) await f.vms.ref(vm.id).update({ idleTimeoutSeconds: Number(process.argv[4]) });
  console.log((await f.vms.get(vm.id)).state);
} else {
  const vm = await f.vms.get(a);
  const { identity } = await f.identities.create();
  await identity.permissions.vm.grant({ vmId: vm.id, allowedLinuxUsers: ["root"] });
  const { token } = await identity.tokens.create();
  console.log(identity.id);
  console.log(`${vm.id}+root:${token}`);
  console.log(`${vm.id}.beta-ssh.freestyle.sh`);
}
