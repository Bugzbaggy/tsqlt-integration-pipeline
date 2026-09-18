#!/usr/bin/env bash
# =============================================================================
# autogen-missing-baselines.sh - create baselines for objects that have NONE yet, without ever
# touching a baseline that already exists. Handles both kinds:
#
#   KIND=contract         -> gen-auto-tests.sh             -> tests/contract/...         test_contract_
#   KIND=characterization -> gen-characterization-tests.sh -> tests/characterization/... test_char_
#
# WHY THE GUARD IS THE WHOLE DESIGN
# Both generators rewrite a WHOLE <schema>.sql. If an EXISTING object's interface or behaviour has
# changed, regenerating that file would overwrite its committed baseline - silently destroying
# exactly the signal these tests exist to raise. So we regenerate, then KEEP the result only when
# the diff is purely ADDITIVE (zero deleted lines). Any deletion means an existing baseline moved:
# revert, and leave it for a human. A brand-new object has no baseline to contradict, so adding
# one is always safe - that is the case this automates away.
#
# THE GUARD FAILS CLOSED. The verdict comes from git; if git cannot answer we refuse rather than
# proceed, because a guard that fails open is worse than no guard.
#
# WHY THREE PHASES
# The generator needs sqlcmd and the guard needs git, and in CI those live in DIFFERENT
# containers of the same pod (mssql-2022 has sqlcmd but no git; dotnet-8 has git but no sqlcmd).
# They share the workspace volume, so each phase runs where its tool is:
#
#   PHASE=precheck   (git)     record, per schema file: is it tracked, is it already dirty
#   PHASE=generate   (sqlcmd)  regenerate the schema files for the objects with no baseline
#   PHASE=verify     (git)     keep only purely-additive results, revert the rest, write reports
#
# PHASE=all (the default) runs all three in order - use it anywhere both tools exist, such as a
# developer's machine or the local-test kit. Running everything in one container that lacks git
# is what made the pipeline stage a silent no-op: the guard exited 2 and the caller swallowed it.
#
#   Env: SERVER PORT SA_PASSWORD SQLCMD_ENC  DB  KIND  PHASE  OUT_ROOT  ARTIFACTS_DIR  LABEL
#   Arg: missing objects ("sch.obj ..."), else read from $ARTIFACTS_DIR/$KIND-missing-$LABEL.txt
#
#   Exit 0 = nothing to do, or baselines added cleanly
#   Exit 3 = refused: regeneration was NOT purely additive (a real change to review)
#   Exit 2 = error / could not verify
# =============================================================================
set -uo pipefail

DB="${DB:-}"
KIND="${KIND:-contract}"
PHASE="${PHASE:-all}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
LABEL="${LABEL:-${DB:-AppDb_MSG}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ARTIFACTS_DIR"

case "$KIND" in
    contract)         GEN=gen-auto-tests.sh;             PREFIX=test_contract_; DEFOUT=tests/contract/AppDb_MSG ;;
    characterization) GEN=gen-characterization-tests.sh; PREFIX=test_char_;     DEFOUT=tests/characterization/AppDb_MSG ;;
    *) echo "ERROR: KIND must be contract or characterization (got '$KIND')" >&2; exit 2 ;;
esac
OUT_ROOT="${OUT_ROOT:-$DEFOUT}"
STATE="$ARTIFACTS_DIR/$KIND-autogen-state-$LABEL.txt"

MISSING="${1:-}"
[ -n "$MISSING" ] || MISSING="$(cat "$ARTIFACTS_DIR/$KIND-missing-$LABEL.txt" 2>/dev/null || true)"
MISSING="$(printf '%s' "$MISSING" | tr -s ' \t\n' ' ' | sed -e 's/^ //' -e 's/ $//')"

if [ -z "$MISSING" ]; then
    echo "==> [$LABEL/$KIND] no missing baselines - nothing to generate."
    case "$PHASE" in precheck|all) : > "$STATE" ;; esac
    exit 0
fi
SCHEMAS="$(for o in $MISSING; do printf '%s\n' "${o%%.*}"; done | sort -u)"

# Fail closed: without a usable git work tree we cannot prove the change is purely additive.
need_git() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 && return 0
    echo "ERROR: [$LABEL/$KIND] not a usable git work tree (phase $PHASE) - cannot prove the" >&2
    echo "       regeneration is purely additive, so refusing to touch any baseline." >&2
    exit 2
}

# ---- PHASE precheck: what did the file look like BEFORE we generated anything? ---------------
# Tracked-ness is still knowable afterwards (generation does not touch the index), but "was it
# already modified" is not - and without that, "zero deleted lines" would be a claim about
# somebody else's edit as much as ours.
phase_precheck() {
    need_git
    : > "$STATE"
    for sch in $SCHEMAS; do
        f="$OUT_ROOT/$sch.sql"
        tracked=0; git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && tracked=1
        dirty=0
        if [ "$tracked" = "1" ] && [ -n "$(git status --porcelain -- "$f" 2>/dev/null)" ]; then dirty=1; fi
        printf '%s %s %s\n' "$sch" "$tracked" "$dirty" >> "$STATE"
    done
    echo "==> [$LABEL/$KIND] precheck: $(wc -l < "$STATE" | tr -d ' ') schema file(s) recorded."
}

# ---- PHASE generate: the only phase that needs a database --------------------------------------
phase_generate() {
    [ -n "$DB" ] || { echo "ERROR: [$LABEL/$KIND] DB must be set to generate." >&2; exit 2; }
    echo "==> [$LABEL/$KIND] objects with no baseline: $MISSING"
    for sch in $SCHEMAS; do
        log="$ARTIFACTS_DIR/$KIND-autogen-gen-$LABEL-$sch.log"
        if ! OUT_ROOT="$OUT_ROOT" bash "$HERE/$GEN" "$DB" --schema "$sch" > "$log" 2>&1; then
            echo "ERROR: [$LABEL/$KIND] generation failed for schema $sch - see $log" >&2
            tail -5 "$log" >&2 || true
            exit 2
        fi
        echo "    $sch: regenerated."
    done
}

# ---- PHASE verify: apply the additive-only rule and report what really happened ---------------
phase_verify() {
    need_git
    refused=""
    for sch in $SCHEMAS; do
        f="$OUT_ROOT/$sch.sql"
        tracked=""; dirty=""
        if [ -f "$STATE" ]; then
            line="$(awk -v s="$sch" '$1==s{print; exit}' "$STATE" 2>/dev/null || true)"
            [ -n "$line" ] && { tracked="$(printf '%s' "$line" | awk '{print $2}')"; dirty="$(printf '%s' "$line" | awk '{print $3}')"; }
        fi
        if [ -z "$tracked" ]; then
            # No precheck state (someone ran verify on its own). Tracked-ness is still reliable;
            # "was it already dirty" is not, so say so rather than pretend we checked.
            echo "    $sch: no precheck state - deriving tracked-ness now, pre-existing local edits cannot be ruled out."
            tracked=0; git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && tracked=1
            dirty=0
        fi

        if [ "$dirty" = "1" ]; then
            echo "    $sch: REFUSED - $f was already modified before generation, so 'zero deleted"
            echo "             lines' would not be a statement about this build's work."
            git checkout -- "$f" 2>/dev/null || true
            refused="$refused $sch"
            continue
        fi

        # A file absent from the index has NO committed baseline to overwrite, so creating it is
        # additive by definition. git diff says nothing about untracked paths, which is why this
        # has to be decided here and not from a numstat.
        if [ "$tracked" = "0" ]; then
            if [ -f "$f" ]; then
                echo "    $sch: new baseline file (untracked) - no committed baseline to overwrite, keeping."
            else
                echo "    $sch: generator produced no file - nothing to add."
            fi
            continue
        fi

        if ! nums="$(git diff --numstat -- "$f" 2>/dev/null | head -1)"; then
            echo "ERROR: [$LABEL/$KIND] git diff failed for $f - reverting and refusing." >&2
            git checkout -- "$f" 2>/dev/null || true
            exit 2
        fi
        if [ -z "$nums" ]; then
            echo "    $sch: regenerated, byte-identical to the committed file (nothing to add)."
            continue
        fi
        add="$(printf '%s' "$nums" | awk '{print $1+0}')"
        del="$(printf '%s' "$nums" | awk '{print $2+0}')"
        if [ "${del:-0}" -gt 0 ]; then
            echo "    $sch: REFUSED - regeneration changed $del existing line(s), not purely additive."
            echo "             An existing baseline moved; that is a real change for a human to review."
            git checkout -- "$f" 2>/dev/null || true
            refused="$refused $sch"
        else
            echo "    $sch: +$add line(s), 0 deletions -> purely additive, keeping."
        fi
    done
    refused="${refused# }"

    # Report what came OUT of this build, per object - not the wish list it started with. An
    # object in a refused (and reverted) schema, or one the generator declined to emit, has no
    # baseline and must not be reported as added.
    still=""; added=""
    for o in $MISSING; do
        sch="${o%%.*}"; obj="${o#*.}"
        skip=0
        for r in $refused; do [ "$r" = "$sch" ] && skip=1; done
        if [ "$skip" = "0" ] && grep -q "${PREFIX}${sch}_${obj}'" "$OUT_ROOT/$sch.sql" 2>/dev/null; then
            added="$added $o"
        else
            still="$still $o"
        fi
    done
    still="${still# }"; added="${added# }"

    printf '%s' "$refused" > "$ARTIFACTS_DIR/$KIND-autogen-refused-$LABEL.txt"
    printf '%s' "$added"   > "$ARTIFACTS_DIR/$KIND-autogen-added-$LABEL.txt"
    # The PR comment reads the missing list AFTER this stage. Leaving the pre-generation snapshot
    # in place made the same comment say "a baseline was generated for you" and "no baseline yet -
    # run the generator" about the same object. Refresh it to what is STILL missing.
    printf '%s' "$still"   > "$ARTIFACTS_DIR/$KIND-missing-$LABEL.txt"

    [ -n "$added" ]   && echo "==> [$LABEL/$KIND] baseline created for: $added"
    [ -n "$still" ]   && echo "==> [$LABEL/$KIND] still without a baseline: $still"
    [ -n "$refused" ] && { echo "==> [$LABEL/$KIND] refused (not purely additive): $refused"; exit 3; }
    return 0
}

case "$PHASE" in
    precheck) phase_precheck ;;
    generate) phase_generate ;;
    verify)   phase_verify ;;
    all)      phase_precheck; phase_generate; phase_verify ;;
    *) echo "ERROR: PHASE must be precheck|generate|verify|all (got '$PHASE')" >&2; exit 2 ;;
esac
exit $?
