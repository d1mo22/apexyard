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

The first round of this AgDR made two inaccurate claims. Rex's probe P1
and Hakim's H1/H3 findings showed both were wrong, not just imprecise.

**Correction 1 — the config data did not always come from
`$REPO_ROOT`.** The Decision section (item 2) said the config always
resolves against `$PWD`, already `cd`-ed into `$REPO_ROOT`. Rex's probe
P1 disproved this. It built an ops repo with `.apexyard-fork` and a
nested `workspace/proj` clone. A push via `-C workspace/proj` ran the
OPS FORK's `.pre_push.commands` against the project's own files.
`_config_repo_root` does not stop at `$PWD`. Per AgDR-0118, it walks up
for the nearest `.apexyard-fork` ancestor. For the documented
`workspace/<name>/` layout, that walk finds the ops fork first. A
session pin (apexyard#381) can cause the same misread from a different
direction. Fix: `pre-push-gate.sh` now sets `_CONFIG_ROOT_CACHE` to
`$REPO_ROOT` right after sourcing the library. This short-circuits the
walk-up and the pin lookup both. The config now always comes from
`$REPO_ROOT`.

**Correction 2 — the trust boundary did change, and not only in the
direction #1366 intended.** The original Decision called the trust model
"unchanged from #1366's own design." The Consequences section said a
target repo "cannot steer which CODE runs, only which DATA." Both
understated the change. Before #1366, no command text could choose the
config source. The hook always ran the session repo's own commands.
After #1366 shipped, the resolution logic scanned the whole command for
any `cd` or `-C` value, with no anchor to a real command position. A
comment, an unrelated `echo`, or a later unrelated git call could make
the hook read a different repository's declared commands (Hakim H1).
A `PreToolUse` hook runs before the operator's permission decision.
This widened the trust surface well past "the session repo runs its
own commands." The original text called that surface unchanged. It was
not.

**The fix, this round:** resolution now trusts exactly one source. That
source is a `-C` flag bound directly to the actual `git ... push`
invocation. A `--git-dir` flag counts for detection only, not for
resolution. The match must sit at a real command position — the start
of the command, or right after `&&`, `||`, `;`, or `|`. Nothing else is
scanned. This closes the crafted-command class of finding (Hakim H3).
An echo, a comment, or an unrelated later git call can no longer steer
which repository's commands run.

**Accepted limit — a leading `cd` is never resolved.** The first round
let a `cd <dir> &&` prefix set the pushed repo. It also joined a
relative `-C` value to that `cd` target, not to `$PWD`. Both were
themselves sources of misreadable, unanchored text. This round drops
`cd`-text parsing entirely. A compound command that changes directory
before pushing now runs against the working directory instead, with a
one-line advisory on stderr. It never runs against the `cd` target. This
is a deliberate narrowing. `git -C <dir> push` remains the supported way
to check a different repository before pushing to it.

## Artifacts

- Issue: me2resh/apexyard#1366
- Review: me2resh/apexyard#1405 (round 1 — Rex item 3, Hakim A1. Round 2 — Rex B1/B2, Hakim H1/H3)
- Related: docs/agdr/AgDR-0169-dispatcher-fail-closed-merge-gates.md
