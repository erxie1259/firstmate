---
name: check-design
description: >-
  Agent-only principles for designing automated checks and merge gates.
  Use before designing, adding, or promoting a merge gate, CI check, or automated pass/fail validation check in a project or in firstmate's own tooling.
  Owns the ratcheted-enforcement rollout rule and the three-outcome contract that keeps an incomplete check from looking like a pass.
user-invocable: false
metadata:
  internal: true
---

# check-design

Apply these two principles whenever designing, adding, or promoting any automated check whose verdict can gate work: a CI job, a merge check, a validation script, a watcher poll, or any other pass/fail automation.
They apply to checks the fleet ships into project repos and to firstmate's own tooling alike.
`firstmate-coding-guidelines` separately owns enforcement style for firstmate's internal safety infrastructure; this skill owns how any new check earns authority and reports its outcome.

## Ratcheted enforcement

A new check starts non-blocking and earns the right to block.

- Introduce every new gate in report-only mode: it runs, reports its findings, and cannot fail the pipeline or block a merge.
- Establish a baseline over an agreed observation window of real runs before any promotion, and measure the false-positive rate against that baseline.
- Promote a check to blocking only through an explicit reviewed change after the owner accepts the observed noise level, never as a default and never silently.
- A blocking check must tell the developer what failed, why, and what to do next; never block on a result the affected developer cannot self-serve diagnose.

**Why:** an unvetted blocking gate gets bypassed or disabled at its first false positive, and a disabled gate protects nothing while still costing maintenance.
Trust in a check is built by observation, not asserted at introduction.

## Incomplete analysis is not a pass

Every check has three distinct outcomes: it ran and passed, it ran and failed, or it could not complete.

- A check that could not complete - missing tool, missing input, unavailable service, timeout, authentication failure - must report that loudly and name the concrete missing requirement.
- It must never exit successfully, because a silent skip converts a broken checker into a green light.
- It must also never present itself as an ordinary failure of the checked code, because that misdirects debugging toward code that was never actually examined.
- Give the incomplete outcome its own distinct exit code or status wherever the surface allows, and make downstream consumers treat it as "unknown", never as "clean".

**Why:** the most dangerous state for a check is not failing noisily but passing vacuously; a check that cannot run must be indistinguishable from a check that was never trusted, not from a check that succeeded.
