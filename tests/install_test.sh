#!/usr/bin/env bash
#
# Dependency-free test runner for install.sh.
#
# Usage: tests/install_test.sh [name-substring]
#
# install.sh is sourced with DOTFILES_LIB_ONLY=1, which defines its functions
# without running main. install.sh sets -e; we turn it back off, because a
# failed assertion must record a failure and keep going rather than kill the run.

set -uo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
filter=${1:-}

DOTFILES_LIB_ONLY=1 . "$repo_root/install.sh"
set +e

tests_run=0
tests_failed=0
tests_skipped=0
skipped_this_test=0
current_test=""
sandboxes=()

cleanup() {
    local s
    for s in ${sandboxes+"${sandboxes[@]}"}; do
        [ -n "$s" ] && rm -rf -- "$s"
    done
}
trap cleanup EXIT

sandbox() {
    local s
    s=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-test.XXXXXX")
    sandboxes+=("$s")
    printf '%s\n' "$s"
}

fail() {
    tests_failed=$((tests_failed + 1))
    printf '  FAIL %s\n       %s\n' "$current_test" "$1"
}

assert_eq() {
    # assert_eq <actual> <expected> <description>
    if [ "$1" != "$2" ]; then
        fail "$3: expected [$2], got [$1]"
    fi
}

assert_contains() {
    # assert_contains <haystack> <needle> <description>
    case "$1" in
        *"$2"*) ;;
        *) fail "$3: expected to find [$2] in [$1]" ;;
    esac
}

assert_ok() {
    # assert_ok <status> <description>
    if [ "$1" != 0 ]; then
        fail "$2: expected success, got status $1"
    fi
}

assert_fails() {
    # assert_fails <status> <description>
    if [ "$1" = 0 ]; then
        fail "$2: expected failure, got success"
    fi
}

skip() {
    # skip <reason> — declare that this test cannot run on this machine.
    #
    # Skipped tests are counted separately and never reported as "ok". A test
    # that did not run but prints a pass is false confidence about coverage,
    # which is exactly how a real bug reached review earlier in this plan.
    tests_skipped=$((tests_skipped + 1))
    skipped_this_test=1
    printf '  skip %s (%s)\n' "$current_test" "$1"
}

run_test() {
    case "$1" in
        *"$filter"*) ;;
        *) return 0 ;;
    esac
    current_test=$1
    skipped_this_test=0
    local before=$tests_failed
    "$1"
    if [ "$skipped_this_test" = 1 ]; then
        return 0
    fi
    tests_run=$((tests_run + 1))
    if [ "$tests_failed" = "$before" ]; then
        printf '  ok   %s\n' "$1"
    fi
}

# --------------------------------------------------------------------------
# resolve()
# --------------------------------------------------------------------------

test_resolve_directory_is_absolute_and_physical() {
    local box
    box=$(sandbox)
    mkdir -p "$box/real"
    assert_eq "$(resolve "$box/real")" "$(cd "$box/real" && pwd -P)" "directory"
}

test_resolve_follows_a_symlinked_directory() {
    local box
    box=$(sandbox)
    mkdir -p "$box/real"
    ln -s -- "$box/real" "$box/link"
    assert_eq "$(resolve "$box/link")" "$(resolve "$box/real")" "symlinked dir"
}

test_resolve_handles_a_plain_file() {
    local box
    box=$(sandbox)
    : > "$box/file"
    assert_eq "$(resolve "$box/file")" "$(cd "$box" && pwd -P)/file" "plain file"
}

test_resolve_handles_a_nonexistent_leaf() {
    local box
    box=$(sandbox)
    assert_eq "$(resolve "$box/missing")" "$(cd "$box" && pwd -P)/missing" "missing leaf"
}

test_resolve_follows_a_symlink_to_a_file() {
    # The case link() actually hits for home/.zshrc and home/.zprofile. A
    # symlink to a file must resolve to its target, not to its own path.
    local box
    box=$(sandbox)
    mkdir -p "$box/repo"
    : > "$box/repo/.zshrc"
    ln -s -- "$box/repo/.zshrc" "$box/link"
    assert_eq "$(resolve "$box/link")" "$(resolve "$box/repo/.zshrc")" "symlink to file"
}

test_resolve_follows_a_relative_symlink() {
    local box
    box=$(sandbox)
    mkdir -p "$box/repo"
    : > "$box/repo/.zshrc"
    ln -s -- "repo/.zshrc" "$box/link"
    assert_eq "$(resolve "$box/link")" "$(resolve "$box/repo/.zshrc")" "relative symlink"
}

test_resolve_fails_on_a_missing_parent() {
    # readlink -f errors here. Returning a fabricated path with status 0 would
    # let a wrong value flow into a backup-and-relink decision.
    local box out status
    box=$(sandbox)
    out=$(resolve "$box/absent/leaf" 2>/dev/null)
    status=$?
    assert_fails $status "missing parent reports failure"
    assert_eq "$out" "" "missing parent prints nothing"
}

test_resolve_detects_a_symlink_loop() {
    local box status
    box=$(sandbox)
    ln -s -- "$box/b" "$box/a"
    ln -s -- "$box/a" "$box/b"
    resolve "$box/a" >/dev/null 2>&1
    status=$?
    assert_fails $status "symlink loop reports failure"
}

run_test test_resolve_directory_is_absolute_and_physical
run_test test_resolve_follows_a_symlinked_directory
run_test test_resolve_handles_a_plain_file
run_test test_resolve_handles_a_nonexistent_leaf
run_test test_resolve_follows_a_symlink_to_a_file
run_test test_resolve_follows_a_relative_symlink
run_test test_resolve_fails_on_a_missing_parent
run_test test_resolve_detects_a_symlink_loop

# --------------------------------------------------------------------------
# detect_platform()
# --------------------------------------------------------------------------

test_detect_platform_honours_the_override() {
    assert_eq "$(DOTFILES_PLATFORM=fedora detect_platform)" "fedora" "override"
}

test_detect_platform_reports_macos_on_darwin() {
    if [ "$(uname -s)" != Darwin ]; then
        skip "not Darwin"
        return 0
    fi
    assert_eq "$(detect_platform)" "macos" "darwin"
}

test_detect_platform_reads_os_release_id_on_linux() {
    if [ "$(uname -s)" != Linux ]; then
        skip "not Linux"
        return 0
    fi
    local expected
    expected=$(. /etc/os-release && printf '%s' "$ID")
    assert_eq "$(detect_platform)" "$expected" "linux"
}

test_detect_platform_does_not_leak_os_release_variables() {
    # /etc/os-release defines ID, NAME, VERSION and friends. Sourcing it in the
    # caller's shell would clobber them, so it must happen in a subshell.
    local ID="sentinel"
    detect_platform >/dev/null
    assert_eq "$ID" "sentinel" "no leak"
}

run_test test_detect_platform_honours_the_override
run_test test_detect_platform_reports_macos_on_darwin
run_test test_detect_platform_reads_os_release_id_on_linux
run_test test_detect_platform_does_not_leak_os_release_variables

printf '\n%d test(s), %d failure(s), %d skipped\n' \
    "$tests_run" "$tests_failed" "$tests_skipped"

# A mistyped filter would otherwise print "0 test(s), 0 failure(s)" and exit 0,
# which reads exactly like a pass.
if [ -n "$filter" ] && [ "$tests_run" = 0 ] && [ "$tests_skipped" = 0 ]; then
    printf 'No test matched filter [%s]\n' "$filter" >&2
    exit 1
fi

[ "$tests_failed" = 0 ]
