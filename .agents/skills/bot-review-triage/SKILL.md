---
name: bot-review-triage
description: >-
  Agent-only procedure for triaging automated reviewer-bot comments on task PRs, such as coderabbitai.
  Use when a PR wake, heartbeat review, or pre-merge check shows unresolved bot review comments, and always before merging a PR that carries any.
  Owns validity triage, fix routing through the task's delivery path, dismissal recording, and the untriaged-comment merge boundary.
user-invocable: false
metadata:
  internal: true
---

# bot-review-triage

Reviewer bots such as coderabbitai comment on some project PRs.
Their comments are leads to verify, never verdicts to obey: bots are confidently wrong often enough that acting on one unexamined is worse than ignoring it.
This skill is the single owner of how the fleet triages those comments and routes the outcome.

## Discover

- On any PR-related wake or heartbeat review, and always before merging, list the PR's reviews and review comments with `gh-axi`, consulting its current help for the command shape.
- Treat any comment author ending in `[bot]` that leaves code-review feedback as an automated reviewer; `coderabbitai` is the known instance today.
- Skip threads already resolved or already answered with a recorded decision.

## Triage each comment

- Judge the comment against the actual diff and the accepted task intent, never by the bot's stated confidence or severity labels.
- **Valid**: it identifies a real defect, broken edge case, or correctness, safety, or security problem in the changed code.
- **Valid but contract-expanding**: a genuine improvement that would change accepted product or engineering behavior; load `ask-user-authority` and treat it exactly as an ask-user finding.
- **Invalid**: factually wrong, a style preference conflicting with the project's own conventions, out of scope for the change, or already handled.
- When validity cannot be judged from the diff alone, read the surrounding code before deciding; never fix or dismiss on the bot's word alone.

## Route the outcome

- Valid, worker still live: steer the worker to fix it through the task's selected delivery path, and revalidate as that path requires; a no-mistakes task's fix goes through its pipeline.
- Valid, worker gone: dispatch follow-up work through the normal lifecycle; hard rule 1 still holds and firstmate never edits the project itself.
- Valid on a firstmate-repo PR with the fleet empty: firstmate may commit the fix directly on the same branch and revalidate through the same pipeline.
- Invalid: record the one-line dismissal reason in the task's backlog note; replying on the thread is optional.
- Contract-expanding: the `ask-user-authority` decision governs, with the same limits under standing `yolo` as any other ask-user finding.

## Merge boundary

- Re-check the PR's comments and reviews immediately before any merge.
- Never merge a PR carrying an untriaged bot comment.
- When the bot has not reviewed the PR, the reason decides the wait: a posted rate-limit or unavailability notice from the bot means the merge proceeds without waiting for its review, while an absent review with no such notice means look for the bot's review and triage it before merging.
- A valid unfixed finding blocks the merge unless the captain explicitly accepts it.
- Routine triage is autonomous under the project's standing posture; batch what happened - suggestions fixed, noise dismissed - into the task's outcome summary instead of escalating each comment.
