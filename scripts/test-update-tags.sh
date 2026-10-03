#!/usr/bin/env bash
# Behavioural tests for scripts/update-tags.sh.
#
# Each test builds a throwaway bare repository to stand in for GitHub and a
# clone to run the script from, so nothing here touches the network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/update-tags.sh"

PASS=0
FAIL=0

git_quiet() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# Creates $REMOTE (bare) and $WORK (clone with one commit on main).
setup() {
    TMP="$(mktemp -d)"
    REMOTE="$TMP/remote.git"
    WORK="$TMP/work"
    git_quiet init --bare "$REMOTE"
    git_quiet clone "$REMOTE" "$WORK"
    git -C "$WORK" config user.name test
    git -C "$WORK" config user.email test@example.com
    commit "first"
    git_quiet -C "$WORK" push origin main
}

teardown() { rm -rf "$TMP"; }

commit() {
    echo "$1" >> "$WORK/file"
    git -C "$WORK" add file
    git_quiet -C "$WORK" commit -m "$1"
}

head_sha() { git -C "$WORK" rev-parse HEAD; }

# Commit a tag on the remote points at (empty if the tag is absent).
remote_target() {
    git -C "$REMOTE" rev-parse --verify -q "refs/tags/$1^{commit}" 2>/dev/null || true
}

# Object id of the tag ref itself on the remote (empty if absent).
remote_tag_object() {
    git -C "$REMOTE" rev-parse --verify -q "refs/tags/$1" 2>/dev/null || true
}

remote_tag_type() {
    git -C "$REMOTE" cat-file -t "refs/tags/$1" 2>/dev/null || true
}

run_script() {
    (cd "$WORK" && "$SCRIPT" "$@")
}

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" == "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $name"
        echo "  expected: '$expected'"
        echo "  actual:   '$actual'"
    fi
}

test_creates_all_tags_on_fresh_remote() {
    setup
    run_script 2.1.288
    check "fresh: exit status" 0 $?
    check "fresh: version tag on remote" "$(head_sha)" "$(remote_target v2.1.288)"
    check "fresh: latest on remote" "$(head_sha)" "$(remote_target latest)"
    check "fresh: major tag on remote" "$(head_sha)" "$(remote_target v2)"
    check "fresh: latest is annotated" tag "$(remote_tag_type latest)"
    check "fresh: major tag is annotated" tag "$(remote_tag_type v2)"
    check "fresh: version tag is annotated" tag "$(remote_tag_type v2.1.288)"
    teardown
}

test_moves_tags_forward_to_new_release() {
    setup
    run_script 2.1.287 >/dev/null 2>&1
    local old
    old="$(head_sha)"
    commit "second"
    git_quiet -C "$WORK" push origin main
    run_script 2.1.288
    check "move: exit status" 0 $?
    check "move: latest moved" "$(head_sha)" "$(remote_target latest)"
    check "move: major tag moved" "$(head_sha)" "$(remote_target v2)"
    check "move: new version tag" "$(head_sha)" "$(remote_target v2.1.288)"
    check "move: old version tag untouched" "$old" "$(remote_target v2.1.287)"
    teardown
}

test_rerun_on_same_commit_changes_nothing() {
    setup
    run_script 2.1.288 >/dev/null 2>&1
    local latest_obj major_obj version_obj
    latest_obj="$(remote_tag_object latest)"
    major_obj="$(remote_tag_object v2)"
    version_obj="$(remote_tag_object v2.1.288)"
    sleep 1  # a recreated annotated tag would get a new timestamp, so a new id
    run_script 2.1.288
    check "rerun: exit status" 0 $?
    check "rerun: latest object unchanged" "$latest_obj" "$(remote_tag_object latest)"
    check "rerun: major tag object unchanged" "$major_obj" "$(remote_tag_object v2)"
    check "rerun: version tag object unchanged" "$version_obj" "$(remote_tag_object v2.1.288)"
    teardown
}

test_existing_version_tag_is_left_alone() {
    setup
    git -C "$WORK" tag -a v2.1.288 -m "hand made"
    git_quiet -C "$WORK" push origin v2.1.288
    local version_obj
    version_obj="$(remote_tag_object v2.1.288)"
    commit "second"
    git_quiet -C "$WORK" push origin main
    run_script 2.1.288
    check "existing: exit status" 0 $?
    check "existing: version tag object unchanged" "$version_obj" "$(remote_tag_object v2.1.288)"
    check "existing: latest still moves" "$(head_sha)" "$(remote_target latest)"
    teardown
}

test_moving_tags_never_disappear_on_update() {
    # Updating must replace the tag in place rather than delete-then-create.
    # A pre-receive hook that rejects deletions proves no delete is attempted.
    setup
    run_script 2.1.287 >/dev/null 2>&1
    cat > "$REMOTE/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r old new ref; do
    if [ "$new" = "0000000000000000000000000000000000000000" ]; then
        echo "deletion of $ref refused" >&2
        exit 1
    fi
done
HOOK
    chmod +x "$REMOTE/hooks/pre-receive"
    commit "second"
    git_quiet -C "$WORK" push origin main
    run_script 2.1.288
    check "no-delete: exit status" 0 $?
    check "no-delete: latest moved" "$(head_sha)" "$(remote_target latest)"
    check "no-delete: major tag moved" "$(head_sha)" "$(remote_target v2)"
    teardown
}

test_major_version_is_derived_from_version() {
    setup
    run_script 3.0.1
    check "major: exit status" 0 $?
    check "major: v3 on remote" "$(head_sha)" "$(remote_target v3)"
    check "major: no v2 on remote" "" "$(remote_target v2)"
    teardown
}

test_missing_version_argument_fails() {
    setup
    run_script >/dev/null 2>&1
    check "noarg: non-zero exit" 1 $?
    check "noarg: nothing pushed" "" "$(remote_target latest)"
    teardown
}

test_creates_all_tags_on_fresh_remote
test_moves_tags_forward_to_new_release
test_rerun_on_same_commit_changes_nothing
test_existing_version_tag_is_left_alone
test_moving_tags_never_disappear_on_update
test_major_version_is_derived_from_version
test_missing_version_argument_fails

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
