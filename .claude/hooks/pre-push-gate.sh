#!/bin/bash
# pre-push-gate.sh — blocks `git push` on red local checks.
#
# Upgraded from an advisory reminder (pre-#111) to a blocking check-runner:
# reads a list of shell commands from `.claude/project-config.*.json`
# (`.pre_push.commands`) and runs them in sequence before the push is
# allowed through. Non-zero exit from any command blocks the push.
#
# This implements the HARD STOP documented in `.claude/rules/pr-workflow.md`
# — "Never push without running CI checks locally." Previously the rule
# was self-discipline; now it's mechanical.
#
# Silent pass conditions (exit 0, no output):
#   - No real `git push` at command position (see below).
#   - No `.claude/project-config.defaults.json` AND no `package.json` in the
#     repo → treat as a non-runnable repo (docs-only, newly-forked, etc.).
#   - HEAD commit subject contains the skip marker `<!-- pre-push: skip -->`
#     → emergency escape hatch; prints a visible WARN and lets the push
#     through. Leaves a grep-able trace so bypasses are auditable.
#
# Configured commands (example, from the shipped defaults):
#   - lint:      npm run lint
#   - typecheck: npm run typecheck
#   - test:      npm run test
#   - build:     npm run build
#
# Skip marker: include the literal string `<!-- pre-push: skip -->` in the
# HEAD commit message (subject or body) to bypass for that one push.
# The hook prints the bypassed command set to stderr so the skip is visible.
#
# SCOPE (me2resh/apexyard#1405 second-round review — narrowed from the
# first fix's `cd`/`-C` scan)
# --------------------------------------------------------------------------
# This hook resolves the pushed repository from ONE source only: a `-C`
# (or `--git-dir`) flag bound directly to the actual `git ... push`
# invocation. A leading `cd <dir>` is NEVER resolved — Rex (B2) and Hakim
# (H1/H3) both found that scanning command text for a `cd` target, even
# scoped to "before the push clause", is not anchored to a real command
# position and can be steered by a crafted command (an echo, a comment, a
# relative `cd .` chain). Dropping `cd`-text parsing entirely removes that
# whole class of finding. A compound command that `cd`s before pushing
# falls back to the working directory and prints a one-line advisory —
# see docs/agdr/AgDR-0170-pre-push-trust-boundary.md for the accepted
# limit this narrowing records.

# HOOK_DIR: this file's own directory, used below to source the shared
# config-reading library from a fixed, trusted location — never from the
# repo the command text names (me2resh/apexyard#1405 review item 3 / A1).
HOOK_DIR="$(cd "$(dirname "$0")" && pwd -P)"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Recognise a push AT COMMAND POSITION ONLY — the start of the whole
# command, or immediately after a top-level `&&`, `||`, `;`, or `|`. Never
# a bare `git push` substring appearing inside a quoted argument, a
# grep/echo pattern, a commit message, or a shell comment (me2resh/apexyard
# #1405 review, Rex B2 / Hakim H1 item 1). The previous version matched
# `\bgit...push\b` ANYWHERE in the command text, so a read-only search or a
# commit message that only MENTIONS a push ran this hook's full check
# suite — including, worst case, a repo-declared `.pre_push.commands` list
# from whatever `-C` value happened to sit nearby in the same string.
#
# Splitting on `&&`/`||`/`;`/`|` is a naive text substitution — NOT quote-
# aware, the same accepted limit this framework's other command splitters
# already carry (see `_lib-detect-bash-write.sh`'s `_bdw_split_top_level`,
# not sourced here on purpose — that file has two contributor PRs open
# against it and this hook needs an independent copy anyway, same shape as
# the existing `\bgit\s+push\b` duplication across block-main-push.sh /
# validate-branch-name.sh / dispatch-bash.sh's `is_push_command`). A
# physical newline in COMMAND is already a segment boundary for free — the
# `while read` loop below reads line by line.
# ---------------------------------------------------------------------------
_pp_split_segments() {
  local cmd="$1"
  local split="$cmd"
  split="${split//&&/$'\n'}"
  split="${split//||/$'\n'}"
  split="${split//;/$'\n'}"
  split="${split//|/$'\n'}"
  printf '%s\n' "$split"
}

# _pp_trim <text>: strips leading whitespace and any leading subshell `(`
# characters (with the whitespace after them) — a subshell push,
# `( git push )`, still opens a real command position.
_pp_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  while [ "${s:0:1}" = "(" ]; do
    s="${s:1}"
    s="${s#"${s%%[![:space:]]*}"}"
  done
  printf '%s' "$s"
}

# _pp_strip_env_assignments <text>: drops leading `VAR=value ` tokens
# (e.g. `GIT_DIR=x git push`) — allowed before `git` per the anchor rule.
_pp_strip_env_assignments() {
  local s="$1"
  while printf '%s' "$s" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]'; do
    s=$(printf '%s' "$s" | sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//')
  done
  printf '%s' "$s"
}

# _pp_consume_flags <text-after-"git ">: strips zero or more leading
# `-C <val>` / `--git-dir <val>` tokens and echoes what remains. Used both
# to check whether `push` is the next word (detection) and, on the matched
# segment, to walk the SAME flags again while collecting `-C` values.
_pp_consume_flags() {
  local rest="$1"
  while :; do
    if printf '%s' "$rest" | grep -qE '^-C[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)([[:space:]]|$)'; then
      rest=$(printf '%s' "$rest" | sed -E 's/^-C[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)[[:space:]]*//')
      continue
    fi
    if printf '%s' "$rest" | grep -qE '^--git-dir(=|[[:space:]]+)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)([[:space:]]|$)'; then
      rest=$(printf '%s' "$rest" | sed -E 's/^--git-dir(=|[[:space:]]+)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)[[:space:]]*//')
      continue
    fi
    break
  done
  printf '%s' "$rest"
}

# _pp_is_push_segment <segment>: does this ONE top-level segment start
# with a real `git ... push` invocation (optional leading env assignments,
# optional `-C`/`--git-dir` flags in between)?
_pp_is_push_segment() {
  local t stripped rest
  t="$(_pp_trim "$1")"
  [ -z "$t" ] && return 1
  stripped="$(_pp_strip_env_assignments "$t")"
  printf '%s' "$stripped" | grep -qE '^git([[:space:]]|$)' || return 1
  rest="$(printf '%s' "$stripped" | sed -E 's/^git[[:space:]]*//')"
  rest="$(_pp_consume_flags "$rest")"
  printf '%s' "$rest" | grep -qE '^push([[:space:]]|$)'
}

# _pp_c_values <segment>: echoes each `-C` value found on the matched push
# segment, one per line, in left-to-right order (a `--git-dir` value is
# skipped — it names the .git directory, not the working tree, and is not
# resolvable the same way).
_pp_c_values() {
  local stripped rest val
  stripped="$(_pp_strip_env_assignments "$(_pp_trim "$1")")"
  rest="$(printf '%s' "$stripped" | sed -E 's/^git[[:space:]]*//')"
  while :; do
    if printf '%s' "$rest" | grep -qE '^-C[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)([[:space:]]|$)'; then
      val=$(printf '%s' "$rest" | grep -oE -- '^-C[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)' | sed -E "s/^-C[[:space:]]+//; s/^[\"']//; s/[\"']\$//")
      printf '%s\n' "$val"
      rest=$(printf '%s' "$rest" | sed -E 's/^-C[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)[[:space:]]*//')
      continue
    fi
    if printf '%s' "$rest" | grep -qE '^--git-dir(=|[[:space:]]+)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)([[:space:]]|$)'; then
      rest=$(printf '%s' "$rest" | sed -E 's/^--git-dir(=|[[:space:]]+)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)[[:space:]]*//')
      continue
    fi
    break
  done
}

# Walk the top-level segments in order. The FIRST one that is a real push
# governs this hook — everything after it (a trailing `-C`, `cd`, comment,
# echo, or push-option value) is never consulted. Also note whether any
# segment BEFORE the push was a `cd` — advisory only, `cd` is never
# resolved.
PUSH_SEG=""
FOUND_PUSH=0
HAD_CD_PREFIX=0
# A here-string (`<<<`), not process substitution (`< <(...)`) — process
# substitution is a syntax ERROR under POSIXLY_CORRECT / `bash --posix`
# (verified empirically). A here-string keeps the loop in the CURRENT
# shell, same as process substitution would, so PUSH_SEG/FOUND_PUSH/
# HAD_CD_PREFIX still persist past the loop.
_SEGMENTS="$(_pp_split_segments "$COMMAND")"
while IFS= read -r _seg; do
  _t="$(_pp_trim "$_seg")"
  [ -z "$_t" ] && continue
  if [ "$FOUND_PUSH" -eq 0 ] && _pp_is_push_segment "$_t"; then
    PUSH_SEG="$_t"
    FOUND_PUSH=1
    continue
  fi
  if [ "$FOUND_PUSH" -eq 0 ] && printf '%s' "$_t" | grep -qE '^cd([[:space:]]|$)'; then
    HAD_CD_PREFIX=1
  fi
done <<< "$_SEGMENTS"

if [ "$FOUND_PUSH" -eq 0 ]; then
  exit 0
fi

# _resolve_dir <value> <base>: joins a relative path to <base>, expanding
# a leading `~` against $HOME (Hakim H1 item 5 — `~`-prefixed values must
# resolve a real target, not just fail closed for lack of trying).
_resolve_dir() {
  local dir="$1" base="$2"
  case "$dir" in
    "~"|"~/"*)
      if [ -n "${HOME:-}" ]; then
        dir="${HOME}${dir#"~"}"
      fi
      ;;
    /*) : ;;
    *) dir="$base/$dir" ;;
  esac
  printf '%s' "$dir"
}

# Resolve the target directory from the push segment's OWN `-C` value(s)
# only — never from a `cd` anywhere in the command (dropped entirely, see
# the SCOPE note at the top of this file). Multiple `-C` flags on the same
# invocation join progressively, left to right, mirroring git's own
# repeated-`-C` semantics (Hakim A2) — each later relative value joins to
# the directory the previous one resolved, not to $PWD.
TARGET_EXPLICIT=0
PUSH_TARGET_DIR="$PWD"
_base="$PWD"
_saw_c=0
_CVALS="$(_pp_c_values "$PUSH_SEG")"
while IFS= read -r _cval; do
  [ -z "$_cval" ] && continue
  _saw_c=1
  _base="$(_resolve_dir "$_cval" "$_base")"
done <<< "$_CVALS"
if [ "$_saw_c" -eq 1 ]; then
  TARGET_EXPLICIT=1
  PUSH_TARGET_DIR="$_base"
fi

REPO_ROOT=$(git -C "$PUSH_TARGET_DIR" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  # An explicit `-C` target was named and it does not resolve to a git
  # repository: BLOCK instead of silently skipping every check
  # (me2resh/apexyard#1405 review item 2, Hakim H1 item 2 — "do not skip").
  # The bare-$PWD case (no `-C` at all) keeps the pre-#1366 behaviour: if
  # the session repo itself is not a git repo, `git push` will fail on its
  # own and this hook running is moot.
  if [ "$TARGET_EXPLICIT" -eq 1 ]; then
    cat >&2 <<MSG
BLOCKED: pre-push-gate cannot resolve the repository this push targets.
Resolved target: ${PUSH_TARGET_DIR}
This is not a git repository, or this shell cannot reach it. A gate that
cannot verify its target fails closed instead of skipping every check.
Fix the -C target and push again.
MSG
    exit 2
  fi
  exit 0
fi

# A leading `cd` was present but is never resolved — say so, since the
# gate is about to check the working directory instead of wherever that
# `cd` pointed. Non-blocking; the accepted limit is recorded in
# docs/agdr/AgDR-0170-pre-push-trust-boundary.md.
if [ "$HAD_CD_PREFIX" -eq 1 ] && [ "$TARGET_EXPLICIT" -eq 0 ]; then
  cat >&2 <<MSG
NOTE: pre-push-gate checked the working directory (${PWD}), not a
'cd' target named earlier in this command. A leading 'cd' is an
accepted limit of this gate — use 'git -C <dir> push' to target a
different repository.
MSG
fi

# Move into the target repo NOW, before the config lookup below. The
# shared config reader (`_lib-read-config.sh`) resolves its own repo root
# from `$PWD` (or an ops-root walk-up), so calling it while `$PWD` is still
# the session's original directory reads the WRONG repo's
# `.pre_push.commands` — the second half of #1366 ("the commands can be
# read from one repo's config and executed against a different repo").
cd "$REPO_ROOT" || exit 0

# ---------------------------------------------------------------------------
# Skip marker — check HEAD commit message for the escape hatch.
# ---------------------------------------------------------------------------

SKIP_MARKER='<!-- pre-push: skip -->'
HEAD_MSG=$(cd "$REPO_ROOT" && git log -1 --format='%B' 2>/dev/null)
# -x: whole-line match only, so prose that mentions the marker inline
# (e.g. a commit that documents the escape hatch) does not trigger it —
# only a line consisting of exactly the marker does. See #1097.
if printf '%s\n' "$HEAD_MSG" | grep -qxF -- "$SKIP_MARKER"; then
  echo "WARN: pre-push gate bypassed by skip marker in HEAD commit message." >&2
  echo "      Skipped commands will run in CI regardless — fix broken state before merging." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Load command list from project config via the shared reader.
# Shipped defaults ship at .claude/project-config.defaults.json.
# See docs/project-config.md and apexyard#109.
# ---------------------------------------------------------------------------

CMDS_JSON=""
# Source the shared reader from THIS HOOK'S OWN directory, never from
# $REPO_ROOT (me2resh/apexyard#1405 review item 3, Hakim A1). $REPO_ROOT is
# a directory named by the command TEXT — sourcing arbitrary shell code
# from a directory the command names, before the permission decision, is a
# code-execution path with no independent trust check. The library that
# INTERPRETS `.pre_push.commands` always comes from the hook's own,
# framework-controlled copy; only the CONFIG DATA (JSON already read from
# $REPO_ROOT via `config_get`, forced below) comes from the target repo —
# the same trust boundary this hook has had since before #1366: a repo's
# `.pre_push.commands` was always free to declare arbitrary shell commands,
# run via `bash -c` below; only the INTERPRETER's location changes here,
# not what a repo may configure. See
# docs/agdr/AgDR-0170-pre-push-trust-boundary.md.
if [ -f "$HOOK_DIR/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$HOOK_DIR/_lib-read-config.sh"
  # Force the config reader to treat $REPO_ROOT as the config root,
  # bypassing `_config_repo_root`'s ops-fork walk-up entirely. Without
  # this, `_config_repo_root` walks UP from $REPO_ROOT looking for the
  # nearest `.apexyard-fork` (or v1 onboarding.yaml + apexyard.projects.
  # yaml) ancestor — which, for the documented `workspace/<name>/` layout,
  # resolves to the OPS FORK itself, not the pushed project, and the gate
  # would run the ops fork's `.pre_push.commands` against the PROJECT's
  # files (me2resh/apexyard#1405 review finding B1, Rex probe P1). Setting
  # the cache directly is the fix Rex's own review suggested — `config_get`
  # -> `_config_defaults_file` / `_config_overrides_file` ->
  # `_config_repo_root` all short-circuit on this cache before any walk-up
  # or session-pin lookup runs, so this REPLACES the previous
  # `APEXYARD_OPS_DISABLE_PIN=1` approach rather than adding to it — that
  # env var only disabled the PIN half of resolution, not the walk-up half
  # B1 actually found broken.
  _CONFIG_ROOT_CACHE="$REPO_ROOT"
  CMDS_JSON=$(config_get '.pre_push.commands' 2>/dev/null)
fi

# Check that the config actually contains commands. Silent skip if not —
# the hook is a no-op on repos that haven't configured any (docs-only
# repos, newly forked skeletons, the apexyard framework repo itself before
# it configures its own CI in a separate ticket).
if [ -z "$CMDS_JSON" ] || [ "$CMDS_JSON" = "null" ] || [ "$CMDS_JSON" = "[]" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Run each command. On first non-zero, block with a summary.
# `$PWD` is already `$REPO_ROOT` from the cd above.
# ---------------------------------------------------------------------------

FAILURES=""
# printf '%s', NOT echo: CMDS_JSON comes from config_get and may carry a JSON
# backslash escape (the markdownlint `tr '\n' '\0'` command). echo would mangle
# it under an escape-interpreting shell, zeroing NUM_CMDS and silently skipping
# every pre-push check. Same bug class as #629. See #631.
NUM_CMDS=$(printf '%s' "$CMDS_JSON" | jq 'length' 2>/dev/null)
if [ -z "$NUM_CMDS" ] || [ "$NUM_CMDS" = "null" ]; then
  exit 0
fi

i=0
while [ "$i" -lt "$NUM_CMDS" ]; do
  NAME=$(printf '%s' "$CMDS_JSON" | jq -r ".[$i].name // \"step-$i\"" 2>/dev/null)
  RUN=$(printf '%s' "$CMDS_JSON" | jq -r ".[$i].run // empty" 2>/dev/null)
  i=$((i + 1))

  if [ -z "$RUN" ]; then
    continue
  fi

  # Run each command capturing last 20 lines for the error report.
  TMP_LOG=$(mktemp -t pre-push-gate.XXXXXX)
  if bash -c "$RUN" >"$TMP_LOG" 2>&1; then
    rm -f "$TMP_LOG"
    continue
  fi

  # Command failed — accumulate a summary. Keep the log for the final
  # block message; clean up after we print.
  TAIL=$(tail -20 "$TMP_LOG" 2>/dev/null)
  rm -f "$TMP_LOG"

  FAILURES="${FAILURES}${NAME}: FAILED
  command: ${RUN}
  last 20 lines of output:
${TAIL}

"
  # Fail-fast: don't keep running subsequent commands once one has failed.
  # (Parallel execution is a follow-up — ticket notes it as a P2 polish.)
  break
done

if [ -n "$FAILURES" ]; then
  cat >&2 <<MSG
BLOCKED: pre-push-gate detected failing check(s). Fix before pushing.

${FAILURES}
To override for a genuine emergency (the fix will run in CI regardless):
  git commit --amend -m "\$(git log -1 --format=%B)
  ${SKIP_MARKER}"

The skip marker is grep-able on purpose — bypasses should be rare and
auditable. See .claude/rules/pr-workflow.md "Before git push (HARD STOP)".
MSG
  exit 2
fi

exit 0
