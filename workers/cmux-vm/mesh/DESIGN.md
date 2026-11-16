# cmux mesh: design (experiment, cx-0op)

The VM mesh experiment's design, its validated facts about the VM provider
and the validation run evidence are internal infrastructure details. They live
in the private platform repo with the cmux VM API's other operator docs
(`docs/vm-mesh/DESIGN.md` there).

In short: a mesh is a private network per team; a cmux VM joins it as a member
and every other device gets its own WireGuard tunnel with the device's public
key. cmux owns identity, enrollment, rotation and the ACL. The experiment is
behind `CMUX_VM_MESH_EXPERIMENT` and `CMUX_VM_MESH_TENANT_IDS` (see
`src/mesh/config.ts`). The validation scripts in `validation/` reproduce each
fact; they write their ledgers to `validation/out/`, which is not committed.

The client-side mesh design (Weft, the coordinator protocol, ACL policy,
relays) is public in `plans/cmux-next/mesh-DESIGN.md`.
