# Pre-push gate: interpreter location and config-source trust boundary

> In the context of `pre-push-gate.sh` reading a push target from the command
> text (AgDR from issue #1366), facing a code-review finding that the config
> LIBRARY sourced from that target could be attacker- or fork-controlled, I
> decided to source the library from the hook's own directory always, and to
> keep the existing rule that any git repository the push resolves to may
> supply its own `.pre_push.commands`. Only the interpreter's location
> changes. What a repo may configure does not.

## Status

Accepted

## Context

Issue me2resh/apexyard#1366 fixed `pre-push-gate.sh` to run its checks
against the repository a push actually targets, read from a `cd <dir> &&`
prefix or a `git -C <dir> push` form, instead of always assuming `$PWD`.

The code-review of the fix (PR #1405, Rex's finding item 3) reported that
the hook sourced `_lib-read-config.sh` from `$REPO_ROOT`, a directory
resolved from the command TEXT:

```
. "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
```

A `PreToolUse` hook runs before the permission decision. Sourcing shell
code from a directory the command names is a code-execution path. No
independent check confirms that directory is safe. A routed push command
that names another clone via `-C` or `cd` would make this hook run
whatever `_lib-read-config.sh` contains in that other clone.

Two separate questions follow from this finding:

1. Where should the LIBRARY CODE that interprets `.pre_push.commands`
   come from?
2. Which repositories may SUPPLY `.pre_push.commands` at all?

## Options Considered — question 1 (library location)

| Option | Pros | Cons |
|--------|------|------|
| Source `_lib-read-config.sh` from `$REPO_ROOT` (as reported) | Matches the target repo's own copy if it customises the library | Runs arbitrary shell code from a directory the command text names, with no trust check |
| Source `_lib-read-config.sh` from the hook's own directory (`HOOK_DIR`, resolved from `$0`) | The interpreter is always the framework-controlled copy shipped with this hook. `_config_repo_root` inside the library still resolves the CONFIG DATA against `$PWD` (already `cd`-ed into `$REPO_ROOT`), so the target repo's own `.pre_push.commands` JSON is still read correctly | A target repo that ships a customised `_lib-read-config.sh` (extra config keys, a different merge rule) would not get that customisation applied — the hook always merges config the framework's own way |

Chosen: source from `HOOK_DIR`. The library's job is to interpret JSON
into a list of commands. A target repo customising HOW that
interpretation happens is not a supported use case for this hook. A
code-execution path with no trust check costs far more than losing an
undocumented customisation.

## Options Considered — question 2 (which repos may supply commands)

| Option | Pros | Cons |
|--------|------|------|
| Restrict to the ops fork only | Narrowest trust surface | Breaks the entire point of #1366 — a portfolio session routinely pushes to sibling managed-project clones, and THEIR own lint/test commands are exactly what should run |
| Restrict to the ops fork + registered `workspace/<project>` clones | Matches the common portfolio shape | Requires resolving the registry at hook time, adds a dependency this hook did not have, and still excludes a legitimate one-off clone (a premium component, a scratch experiment) that #1366's own bug report used as its motivating example |
| Any git repository the push resolves to (unchanged from #1366's own design) | No new restriction. Matches what #1366 explicitly built | The DATA (declared commands) is still repo-controlled, same as every `.pre_push.commands` config since before #1366 |

Chosen: any git repository the push resolves to may still supply its own
`.pre_push.commands`. This is not a new decision. It is the existing
trust model, unchanged since before #1366. A repo's own
`.claude/project-config.json` has always been free to declare arbitrary
shell commands. The hook has always run them via `bash -c`. Running a
repo's own declared checks against a push to that repo is the feature,
not a gap. `.claude/rules/isolated-builds.md` and the portfolio model
already assume an operator resolves each repo's own working copy before
building or pushing against it. This hook extends the same assumption to
the check-runner. It does not go beyond it.

## Decision

1. `pre-push-gate.sh` sources `_lib-read-config.sh` from its own directory
   (`HOOK_DIR`, resolved the same way `dispatch-bash.sh` resolves its own
   directory), never from `$REPO_ROOT`.
2. `config_get` still resolves the CONFIG DATA against `$PWD`, which the
   hook has already `cd`-ed into `$REPO_ROOT` before this point — the
   target repo's own `.pre_push.commands` is read correctly.
3. Any git repository a push resolves to may declare `.pre_push.commands`,
   unchanged from #1366's own design. This AgDR records that as a
   deliberate choice, not an oversight — the alternative (restricting to a
   named allowlist of repos) would defeat #1366's stated purpose.

## Consequences

- The interpreter that reads `.pre_push.commands` is always the
  framework's own copy, shipped with the hook. A target repo cannot steer
  which CODE runs, only which DATA (declared shell commands) it supplies —
  the same trust boundary every `.pre_push.commands` config already had.
- A target repo that shipped a customised `_lib-read-config.sh` (not a
  documented or tested configuration) loses that customisation. No known
  adopter relies on this.
- The test sandbox harness (`test_pre_push_gate.sh`'s `make_sandbox`)
  already copies `_lib-read-config.sh` next to the hook in each sandbox,
  so `HOOK_DIR`-based sourcing needs no test-harness change.

## Round 2 addendum — narrower resolution, corrected claims (me2resh/apexyard#1405 second review)

The first round of this AgDR shipped two inaccurate statements. Rex's
probe P1 and Hakim's H1/H3 findings on the second review round showed
both were wrong, not just imprecise.

**Correction 1 — the config data did NOT resolve against `$REPO_ROOT`.**
The Decision section above (item 2) said `config_get` resolves the
config data against `$PWD`, which the hook had already `cd`-ed into
`$REPO_ROOT`. Rex's probe P1 built an ops repo with `.apexyard-fork` and
a nested `workspace/proj` clone, pushed via `-C workspace/proj`, and
observed the OPS FORK's `.pre_push.commands` run against the project's
files. The reason: `_config_repo_root` (inside `_lib-read-config.sh`)
does not stop at `$PWD` — it walks UP looking for the nearest
`.apexyard-fork` (or v1 onboarding pair) ancestor, per AgDR-0118, and for
the documented `workspace/<name>/` layout that walk finds the ops fork
before it finds `$REPO_ROOT`. A session pin (apexyard#381) can do the
same thing from a different direction. Fix: `pre-push-gate.sh` now sets
`_CONFIG_ROOT_CACHE="$REPO_ROOT"` immediately after sourcing the library,
which short-circuits `_config_repo_root`'s cache check before any walk-up
or pin lookup runs. The config now always comes from `$REPO_ROOT` itself,
with no exception.

**Correction 2 — the trust boundary DID change, and not only in the
direction #1366 intended.** The original Decision said any git
repository a push resolves to may supply `.pre_push.commands`, "unchanged
from #1366's own design," and the Consequences section said a target
repo "cannot steer which CODE runs, only which DATA." Both undersold the
actual change. Before #1366, the command TEXT could not choose the
config source at all — the hook always ran the session repo's own
commands. After #1366 shipped (and before this round's fix), the
resolution logic scanned the WHOLE command for any `cd` or `-C` value,
with no anchor to a real command position — so a comment, an unrelated
`echo`, or a later unrelated git invocation could make the hook read (and
run) a DIFFERENT repository's declared commands, including one a
`PreToolUse` hook reaches before the operator's permission decision
(Hakim H1). That is a materially wider trust surface than "the session
repo runs its own commands," and the original Consequences section
described it as unchanged. It was not.

**The fix, this round:** resolution now trusts exactly one thing — a
`-C` (or `--git-dir`, detection-only) flag bound directly to the actual
`git ... push` invocation, matched only at a real command position (the
start of the command, or immediately after `&&`/`||`/`;`/`|`). Nothing
else is scanned. This closes the crafted-command class of finding (Hakim
H3): an echo, a comment, or an unrelated later git call can no longer
steer which repository's commands run.

**Accepted limit — a leading `cd` is never resolved.** The first round
also let a `cd <dir> &&` prefix set the pushed repo, and joined a
relative `-C` value to that `cd` target instead of to `$PWD`. Both
were themselves sources of misreadable, unanchored text. This round
drops `cd`-text parsing entirely: a compound command that changes
directory before pushing runs against the WORKING DIRECTORY instead,
with a one-line advisory on stderr, never against the `cd` target. This
is a deliberate narrowing, not an oversight — `git -C <dir> push` remains
the supported way to check a different repository's commands before
pushing to it.

## Artifacts

- Issue: me2resh/apexyard#1366
- Review: me2resh/apexyard#1405 (round 1: Rex item 3, Hakim A1; round 2: Rex B1/B2, Hakim H1/H3)
- Related: docs/agdr/AgDR-0169-dispatcher-fail-closed-merge-gates.md
