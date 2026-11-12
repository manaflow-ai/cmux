# Security incident response overview

Report a suspected vulnerability using [SECURITY.md](../../SECURITY.md).
That policy is the source of truth for the reporting address, supported
versions, follow-up, and researcher credit. Keep exploit details out of public
issues, pull requests, and chat.

This page outlines the response workflow. The operational plan, responder
contacts, and active investigation records belong in restricted maintainer
documentation. This overview does not introduce a response-time guarantee.

## From report to recovery

1. **Receive and assess.** Maintainers aim to acknowledge the report, establish a
   private way to follow up, and assess affected versions, services, data,
   attacker prerequisites, and evidence of exploitation. A suspected active
   compromise needs incident handling even before the root cause is known.
2. **Contain.** Responders limit further exposure while preserving evidence.
   The appropriate action depends on the incident and can include restricting
   an affected service or invalidating compromised credentials.
3. **Fix and verify.** Maintainers address the cause, check related entry points,
   and verify both the attack being blocked and legitimate use still working.
   A source patch, a released client update, and a deployed service fix are
   separate milestones.
4. **Communicate.** Maintainers coordinate disclosure with the reporter, explain
   affected versions and practical mitigations, and publish confirmed fixes in
   release notes. Where appropriate, a security advisory supplies additional
   detail. Affected users may need direct notice before general disclosure.
5. **Learn.** Responders review what happened, assign follow-up work, and update
   the threat model and response procedures. A public account, when useful,
   excludes private customer data and material that would enable continuing harm.

## What belongs in public communication

Useful information includes affected products or versions, the impact and
attacker prerequisites, fixed versions, mitigation steps, whether users need to
update or replace credentials, and researcher credit consistent with
[SECURITY.md](../../SECURITY.md). Distinguish confirmed facts from questions
still under investigation; absence of evidence is not proof that no one was
affected.

Customer records, credentials, raw diagnostic bundles, unpublished exploit
details, responder contact lists, and internal recovery procedures stay private.
Detailed technical explanations can be published once disclosure is coordinated
and sensitive material has been removed.

## If you think you are affected

Contact the reporting address with the cmux version, approximate time and time
zone, observed behavior, and any relevant Request ID or Trace ID. Share only
the minimum information needed; terminal output and screenshots can contain
secrets. Follow mitigation instructions specific to the incident and use the
fixed release when available.
