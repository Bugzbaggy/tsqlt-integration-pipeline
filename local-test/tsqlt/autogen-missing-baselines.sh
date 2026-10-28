#!/usr/bin/env bash
# =============================================================================
# autogen-missing-baselines.sh - create baselines for objects that have NONE yet, without ever
# touching a baseline that already exists. Handles both kinds:
#
#   KIND=contract         -> gen-auto-tests.sh             -> tests/contract/...         test_contract_
#   KIND=characterization -> gen-characterization-tests.sh -> tests/characterization/... test_char_
#
# WHY THE GUARD IS THE WHOLE DESIGN
# Both generators rewrite a WHOLE <schema>.sql, and overwriting a committed baseline would silently
# destroy exactly the signal these tests exist to raise. So generation goes to a SCRATCH tree and
# only the missing objects' class blocks are APPENDED to the committed file: additive by
# construction, not by diffing afterwards. A zero-deletions check still runs, but as an assertion
# rather than the rule. (The earlier design regenerated in place and kept the result only when the
# diff was purely additive - which refused a whole schema whenever any unrelated object in it had
# drifted, so a new object got no baseline because of one it had nothing to do with.)
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
#   PHASE=verify     (git)     append the missing objects' blocks, classify the rest, write reports
#
# PHASE=all (the default) runs all three in order - use it anywhere both tools exist, such as a
# developer's machine or the local-test kit. Running everything in one container that lacks git
# is what made the pipeline stage a silent no-op: the guard exited 2 and the caller swallowed it.
#
#   Env: SERVER PORT SA_PASSWORD SQLCMD_ENC  DB  KIND  PHASE  OUT_ROOT  ARTIFACTS_DIR  LABEL
#   Arg: missing objects ("sch.obj ..."), else read from $ARTIFACTS_DIR/$KIND-missing-$LABEL.txt
#
#   Exit 0 = nothing to do, or baselines added cleanly
#   Exit 3 = nothing was added for at least one schema: generation failed, the file had local
#            edits, or appending would have rewritten an existing line. The three are reported
#            separately in *-autogen-genfailed-* / -localedits- / -refused-.
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
FAILED="$ARTIFACTS_DIR/$KIND-autogen-failed-$LABEL.txt"
# Generation goes here first, never straight over the committed baseline - see phase_verify.
TMPGEN="$ARTIFACTS_DIR/autogen-gen/$KIND-$LABEL"

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

# Read a field the precheck recorded: state_get <schema> <2=tracked|3=dirty>. Empty when there is
# no state file (someone ran a later phase on its own).
state_get() {
    [ -f "$STATE" ] || return 0
    awk -v s="$1" -v fld="$2" '$1==s{print $fld; exit}' "$STATE" 2>/dev/null
}

# ---- PHASE precheck: what did the file look like BEFORE we generated anything? ---------------
# Tracked-ness is still knowable afterwards (generation does not touch the index), but "was it
# already modified" is not - and without that, "zero deleted lines" would be a claim about
# somebody else's edit as much as ours.
phase_precheck() {
    need_git
    : > "$STATE"
    : > "$FAILED"
    dirty_any=""
    for sch in $SCHEMAS; do
        f="$OUT_ROOT/$sch.sql"
        tracked=0; git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && tracked=1
        dirty=0
        # NOT gated on tracked: a hand-written baseline that was never `git add`ed is exactly the
        # work most worth protecting, and it reported dirty=0, was overwritten, and then kept as a
        # "new baseline file (untracked)". git status prints ?? for it; -uall so a file inside an
        # untracked directory is listed individually rather than collapsed to the directory.
        if [ -n "$(git status --porcelain -uall -- "$f" 2>/dev/null)" ]; then dirty=1; fi
        [ "$dirty" = "1" ] && dirty_any="$dirty_any $sch"
        printf '%s %s %s\n' "$sch" "$tracked" "$dirty" >> "$STATE"
    done
    echo "==> [$LABEL/$KIND] precheck: $(wc -l < "$STATE" | tr -d ' ') schema file(s) recorded."
    if [ -n "$dirty_any" ]; then
        echo "==> [$LABEL/$KIND] NOT generating for${dirty_any} - uncommitted local edits."
    fi
    return 0
}

# ---- PHASE generate: the only phase that needs a database --------------------------------------
phase_generate() {
    [ -n "$DB" ] || { echo "ERROR: [$LABEL/$KIND] DB must be set to generate." >&2; exit 2; }
    # Refuse without precheck state. The phases are separate `|| true` invocations in CI, so a
    # precheck that died (git unusable, a safe.directory problem) used to leave no state, every
    # state_get returned empty, the dirty check silently passed, and generation went ahead
    # unguarded - with verify then failing the same way and never cleaning up.
    if [ ! -f "$STATE" ]; then
        echo "ERROR: [$LABEL/$KIND] no precheck state at $STATE - the precheck phase did not run or" >&2
        echo "       could not use git. Refusing to generate without it." >&2
        exit 2
    fi
    mkdir -p "$TMPGEN"
    echo "==> [$LABEL/$KIND] objects with no baseline: $MISSING"
    for sch in $SCHEMAS; do
        if [ -z "$(state_get "$sch" 2)" ]; then
            echo "ERROR: [$LABEL/$KIND] $sch is not in the precheck state - refusing to generate it." >&2
            # Write the log too. This refusal happens BEFORE the per-schema log is created below,
            # but the schema still lands in $FAILED, and the Jenkinsfile's genfailed branch tells
            # the reader to "see the archived *-autogen-gen-*.log" - which would not exist. Leave
            # one saying what actually happened, so the pointer resolves and nobody hunts for a
            # generator error that never occurred: the cause is precheck/state, not the generator.
            printf '%s\n' "$sch is not in the precheck state ($STATE); generation was not attempted." \
                > "$ARTIFACTS_DIR/$KIND-autogen-gen-$LABEL-$sch.log"
            printf '%s\n' "$sch" >> "$FAILED"
            continue
        fi
        # Never regenerate over local edits. verify appends to the committed file, so a file with
        # uncommitted changes is left alone entirely rather than appended to.
        if [ "$(state_get "$sch" 3)" = "1" ]; then
            echo "    $sch: skipped - the baseline file has uncommitted local edits."
            continue
        fi
        log="$ARTIFACTS_DIR/$KIND-autogen-gen-$LABEL-$sch.log"
        # Cleared FIRST: it was only removed when generation failed, so a run that emitted
        # nothing left the previous run's file in place and verify appended a stale block -
        # for characterization, an out-of-date captured output. CI is safe via cleanWs(), the
        # PHASE=all local path was not.
        rm -f "$TMPGEN/$sch.sql"
        # Generated into a SCRATCH tree, never over the committed file. What gets committed is
        # decided in verify, block by block - see the comment there.
        if ! OUT_ROOT="$TMPGEN" bash "$HERE/$GEN" "$DB" --schema "$sch" > "$log" 2>&1; then
            echo "ERROR: [$LABEL/$KIND] generation failed for schema $sch - see $log" >&2
            tail -5 "$log" >&2 || true
            printf '%s\n' "$sch" >> "$FAILED"
            rm -f "$TMPGEN/$sch.sql"
            continue
        fi
        echo "    $sch: regenerated into $TMPGEN/$sch.sql"
    done
    [ -s "$FAILED" ] && return 2
    return 0
}

# Extract ONE object's test class from a generated schema file. Both generators emit a block per
# object: a blank line, then "-- <schema>.<object> (...)", then the class, up to the next such
# comment or EOF.
#
# Case-insensitively, for the same reason the runners match class names that way: these names come
# from repo FILE PATHS while the generator writes the catalog spelling, and the two can differ
# only in case (a file svc.AuthAPI_GetAll.sql for the object svc.AuthApi_GetAll). A case-sensitive
# match would find no block and report "no automated baseline is possible" for a class the
# generator did emit.
extract_block() {
    awk -v start="-- $1.$2 " -v start2="-- $1.$2(" -v pfx="-- $1." '
        BEGIN { start = tolower(start); start2 = tolower(start2); pfx = tolower(pfx) }
        { low = tolower($0) }
        index(low, start) == 1 || index(low, start2) == 1 { inblk = 1; print; next }
        inblk && index(low, pfx) == 1 { exit }
        inblk { print }
    ' "$3"
}

# Every object of $1 that is still on the missing list, for the per-schema classifications below.
objects_of_schema() {
    for o in $MISSING; do
        [ "${o%%.*}" = "$1" ] && printf '%s ' "$o"
    done
}

phase_verify() {
    need_git
    # Refuse without precheck state, exactly as generate does. The phases are separate `|| true`
    # invocations in CI, so a precheck that died left verify deriving tracked-ness, finding no
    # scratch file, and reclassifying every untried object as "no baseline is possible" - which
    # also takes them OFF the missing list. A precheck failure silently turned "needs a baseline"
    # into "needs a hand-written test". Fail closed instead.
    if [ ! -f "$STATE" ]; then
        echo "ERROR: [$LABEL/$KIND] no precheck state at $STATE - the precheck phase did not run" >&2
        echo "       or could not use git. Refusing to classify anything without it." >&2
        exit 2
    fi
    # Three distinct outcomes, three lists. They used to share one "refused" file, and the message
    # attached to it said an existing baseline would have been rewritten - which, since blocks are
    # appended and the additive property now holds by construction, is the LEAST likely of the
    # three. A transient generator failure was being reported to the author as an interface change
    # in an object they may never have touched.
    genfailed=""; localedits=""; nonadditive=""; unsupported=""
    for sch in $SCHEMAS; do
        f="$OUT_ROOT/$sch.sql"
        src="$TMPGEN/$sch.sql"
        created_here=0
        appended=0
        tracked="$(state_get "$sch" 2)"
        dirty="$(state_get "$sch" 3)"
        if [ -z "$tracked" ]; then
            # The state file exists but this schema is not in it - precheck never saw it, so we
            # cannot know whether the committed file has local edits. Refuse rather than guess:
            # guessing is what reclassified untried objects as "no baseline is possible".
            echo "    $sch: REFUSED - not recorded by the precheck phase, so its state is unknown."
            genfailed="$genfailed $sch"
            continue
        fi

        if grep -qx -- "$sch" "$FAILED" 2>/dev/null; then
            echo "    $sch: generation FAILED; nothing was written to the committed file."
            rm -f "$src"
            genfailed="$genfailed $sch"
            continue
        fi
        if [ "$dirty" = "1" ]; then
            echo "    $sch: SKIPPED - $f has uncommitted local edits, so it was never regenerated."
            echo "             Commit or stash them and re-run if you want a baseline added here."
            localedits="$localedits $sch"
            continue
        fi
        # Generation succeeded and still produced no file: both generators write the schema header
        # only just before their FIRST emitted test, so "no file" means every object in the schema
        # was skipped (a seeded call returning NULL, an error, the 8000-char cap). That is not a
        # to-do - no command will produce these - so the objects are unsupported, not missing.
        if [ ! -f "$src" ]; then
            echo "    $sch: the generator emitted nothing for this schema - no baseline is possible for its objects."
            unsupported="$unsupported $(objects_of_schema "$sch")"
            continue
        fi

        # APPEND the missing objects' blocks; never rewrite what is already committed.
        #
        # The old rule regenerated the whole <schema>.sql and kept it only when the diff had zero
        # deletions. That refused the whole schema whenever ANY other object in it had moved - so a
        # PR that changed svc.A's parameters and added svc.B got no baseline for B, and the refusal
        # notice blamed "an object you may not have touched" for the object the author did change.
        # Appending only the new blocks makes the operation additive BY CONSTRUCTION rather than by
        # diffing after the fact. (The blocks land at the end of the file rather than in sorted
        # position; the next full regeneration by a human reorders them.)
        for o in $(objects_of_schema "$sch"); do
            oobj="${o#*.}"
            blk="$(extract_block "$sch" "$oobj" "$src")"
            if [ -z "$blk" ]; then
                echo "    $o: the generator produced no class for it (see $ARTIFACTS_DIR/$KIND-autogen-gen-$LABEL-$sch.log)"
                unsupported="$unsupported $o"
                continue
            fi
            # Created LAZILY, on the first real block: creating it up-front left a header-only file
            # behind whenever every object turned out to be unsupported, which `git status` then
            # read as "a baseline was generated" - and with AUTO_COMMIT_BASELINES on, committed it.
            if [ ! -f "$f" ]; then
                mkdir -p "$(dirname "$f")"
                sed -n '1,/^-- =\+$/p' "$src" > "$f"
                created_here=1
                echo "    $sch: new baseline file created from the generated header."
            fi
            printf '\n%s\n' "$blk" >> "$f"
            appended=$((appended+1))
            echo "    $o: class appended."
        done
        if [ "$created_here" = "1" ] && [ "$appended" = "0" ]; then
            rm -f "$f"
        fi
        [ "$appended" = "0" ] && continue

        # The append is additive by construction; this is the assertion that proves it, and the
        # one place a bug in extract_block could still be caught before anything is committed.
        if nums="$(git diff --numstat -- "$f" 2>/dev/null | head -1)"; then
            del="$(printf '%s' "$nums" | awk '{print $2+0}')"
            if [ "${del:-0}" -gt 0 ]; then
                echo "    $sch: REFUSED - appending changed $del existing line(s), which must never happen."
                git checkout -- "$f" 2>/dev/null || true
                nonadditive="$nonadditive $sch"
            fi
        else
            echo "ERROR: [$LABEL/$KIND] git diff failed for $f - reverting and refusing." >&2
            git checkout -- "$f" 2>/dev/null || true
            exit 2
        fi
    done
    genfailed="${genfailed# }"; localedits="${localedits# }"
    nonadditive="${nonadditive# }"; unsupported="$(printf '%s' "$unsupported" | tr -s ' ' ' ' | sed -e 's/^ //' -e 's/ $//')"

    # Report what came OUT of this build, per object - not the wish list it started with.
    still=""; added=""
    for o in $MISSING; do
        sch="${o%%.*}"; obj="${o#*.}"
        skip=0
        for r in $nonadditive $genfailed $localedits; do [ "$r" = "$sch" ] && skip=1; done
        if [ "$skip" = "0" ] && grep -qiF -- "${PREFIX}${sch}_${obj}'" "$OUT_ROOT/$sch.sql" 2>/dev/null; then
            added="$added $o"
        else
            still="$still $o"
        fi
    done
    still="${still# }"; added="${added# }"

    printf '%s\n' "$nonadditive" > "$ARTIFACTS_DIR/$KIND-autogen-refused-$LABEL.txt"
    printf '%s\n' "$genfailed"   > "$ARTIFACTS_DIR/$KIND-autogen-genfailed-$LABEL.txt"
    printf '%s\n' "$localedits"  > "$ARTIFACTS_DIR/$KIND-autogen-localedits-$LABEL.txt"
    printf '%s\n' "$added"       > "$ARTIFACTS_DIR/$KIND-autogen-added-$LABEL.txt"
    printf '%s\n' "$unsupported" > "$ARTIFACTS_DIR/$KIND-autogen-unsupported-$LABEL.txt"
    # The PR comment reads the missing list AFTER this stage. Objects the generator cannot produce
    # a class for are NOT left on it - a warning telling you to run a command that will never help
    # is the drift this whole mechanism exists to avoid; they are reported in their own state.
    for o in $unsupported; do
        still="$(printf '%s' "$still" | tr ' ' '\n' | grep -vxF -- "$o" | tr '\n' ' ')"
    done
    still="$(printf '%s' "$still" | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')"
    printf '%s\n' "$still"       > "$ARTIFACTS_DIR/$KIND-missing-$LABEL.txt"

    [ -n "$added" ]       && echo "==> [$LABEL/$KIND] baseline created for: $added"
    [ -n "$unsupported" ] && echo "==> [$LABEL/$KIND] no baseline is possible for: $unsupported (needs a curated test)"
    [ -n "$still" ]       && echo "==> [$LABEL/$KIND] still without a baseline: $still"
    [ -n "$genfailed" ]   && echo "==> [$LABEL/$KIND] generation failed for: $genfailed"
    [ -n "$localedits" ]  && echo "==> [$LABEL/$KIND] skipped (local edits): $localedits"
    [ -n "$nonadditive" ] && echo "==> [$LABEL/$KIND] refused, would have rewritten an existing baseline: $nonadditive"
    if [ -n "$genfailed$localedits$nonadditive" ]; then exit 3; fi
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
