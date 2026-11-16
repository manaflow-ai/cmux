# cmux mesh M1: first working slice (cx-0op)

The M1 plan (flag, Worker endpoints, resources, agent and validation steps for
the VM mesh experiment) carries internal infrastructure details. It lives in
the private platform repo next to the mesh design (`docs/vm-mesh/M1-PLAN.md`
there). The code it planned is in this Worker: `src/api/mesh.ts`,
`src/handlers/mesh.ts`, `src/mesh/`, migration `0004_cmux_vm_mesh.sql` and
`test/workers/mesh.test.ts`.
