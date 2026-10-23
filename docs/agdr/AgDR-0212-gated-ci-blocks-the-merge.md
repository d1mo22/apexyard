# AgDR-0212 — A gated workflow run blocks the merge; a repo with no CI still does not

> In the context of `block-merge-on-red-ci.sh`, facing `gh pr checks` printing the identical "no checks reported" line for a repo with no CI and for a fork PR whose workflow waits at GitHub's approval gate, I decided to distinguish the two with the Actions API and refuse only the `action_required` case, to close a fail-open in a merge gate without introducing false refusals, accepting two extra API calls on an already-rare path and a residual state the gate still cannot see.

## Context

The gate's job is to refuse a merge that CI has not validated. It branched on a substring of `gh pr checks` output:

```sh
if echo "$CHECKS_OUTPUT" | grep -q "no checks reported"; then
  echo "NOTE: PR #N has no CI checks configured. Merge-on-red-CI gate is a no-op for this PR." >&2
  exit 0
fi
```

`gh` prints that line for at least three different states, and the gate treated all of them as the first:

1. The repo genuinely has no CI. Allowing is correct and was this branch's intent.
2. A fork PR whose workflow run sits at `action_required` — GitHub's "Approve and run workflows" gate. CI is configured and has never run. Allowing defeats the gate.
3. Workflows exist but none matched this head, through path or branch filters. Allowing is reasonable; the note is still wrong.

Observed on a real public PR the author has open as an outside contributor: five active workflows, a run at `action_required` for the head, and `gh pr checks` reporting nothing. Fed to the gate, it exits 0 and tells the operator the repo has no CI. A force-push re-arms that approval gate even after a maintainer approved an earlier head, so this is not only a first-contribution state.

Rail 1 of `.claude/rules/agdr-decisions.md` makes any change to `.claude/hooks/**` material, and this changes a gate's verdict.

### Relationship to #1523

Issue #1523 landed on `dev` while this work was in review, and fixed a different defect in the same branch: the guard matched `no checks reported` as a **substring**, so a contributor-controlled check *name* containing that phrase sent a red PR down the allow path. It now requires a non-zero exit and an exact whole-output match.

The two are orthogonal and compose. That change tightened **when** this arm is entered; this decision is about **what to do once inside it**. Verified after merging `dev`: with #1523's guard in place, the gated-workflow case still exits 0 and allows the merge, and 5 of this change's 6 cases still fail against current `dev`.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| (a) Leave it; document the limitation | No new API calls, no false-refusal risk | Leaves a fail-open in the gate whose only purpose is refusing unvalidated merges, and leaves a note that states the opposite of the truth |
| (b) Block on every "no checks reported" | Simple, maximally safe | Breaks every adopter whose repo genuinely has no CI — the case the branch was written for. Turns a working configuration into a hard block |
| (c) Require the operator to pass a flag when a repo has no CI | Explicit | Moves a detection problem onto the operator, and an operator who is wrong once configures the bypass permanently |
| (d) **Distinguish via the Actions API; refuse only `action_required`** | Closes the fail-open; keeps the genuine no-CI allow untouched; the misleading note is corrected for every state; costs nothing on the common path | Two extra API calls on the rare path; still cannot see a state where GitHub reports neither a check nor a run |

## Decision

Chosen: **(d)**.

When, and only when, `gh pr checks` reports no checks:

1. Count active workflows in the **base** repo. Zero means no CI — allow, with the original note, unchanged.
2. Non-zero, and a run for the head SHA is at `action_required` — **block**, exit **2**, naming the approval gate and how to clear it. Exit 2, not 1: Claude Code blocks a `PreToolUse` call only on exit 2, and while the dispatcher maps 1 to 2 today, a direct hook wiring would read exit 1 as a warning and let the merge run. A "block" that exits 1 is not reliably a block. Every other refusal in this hook exits 2.

   The query is `actions/runs?head_sha=<sha>&status=action_required`, read as `.total_count`. Filtering server-side and taking the unpaginated total means a head with more than one page of runs cannot push the gated ones out of view.
3. Non-zero with no such run — allow, but the note says workflows exist and no run matched this head, rather than claiming there is no CI.
4. Either value unresolvable — allow, with a note saying so. A hook that cannot identify the repo or the head must not invent a refusal.

Case 3 stays an allow deliberately. Path and branch filters make "workflows exist, none ran" a normal state, and blocking it would convert a working configuration into a refusal — the failure mode option (b) was rejected for.

## Consequences

- One class of unvalidated merge is now refused instead of permitted, and the refusal names the exact action that clears it.
- The note is accurate in every branch. The previous wording actively misled: it told the operator no CI was configured when five workflows were.
- Two API calls are added on a path that only runs when no checks are reported. The common green and red paths are untouched.
- A network failure cannot create a new refusal. Every unresolvable result falls through to the prior allow.
- **The gate still cannot see case 3's dangerous cousin**: a repo whose workflows were disabled, or whose CI wiring was removed, looks identical to path-filtered. That is unchanged from before this decision and is not made worse by it, but it is the residual and should not be forgotten.
- The mirror hook for GitLab is untouched. `glab` reports pipeline status through a different field that does not share this ambiguity.

## Artifacts

- Issue: me2resh/apexyard#1519
- Rule: `.claude/rules/agdr-decisions.md` rail 1 (trust-chain changes are material at any size)
- Tests: `.claude/hooks/tests/test_block_merge_on_red_ci.sh` — 6 cases; 5 fail against the pre-fix hook, the gated case exiting 0 with the false note
