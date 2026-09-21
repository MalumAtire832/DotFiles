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
    # A test that called skip and then failed an assertion anyway is a
    # test-authoring bug (a missing return after skip). Report it as a
    # failure: a failure that appeared in no counted test reads as noise.
    if [ "$skipped_this_test" = 1 ] && [ "$tests_failed" = "$before" ]; then
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
# os_release_id()
#
# These take a fixture path, so they exercise the Linux parsing on any
# platform. A test that can only run on Fedora is a test this machine cannot
# run at all.
# --------------------------------------------------------------------------

test_os_release_id_reads_an_unquoted_id() {
    # Fedora writes ID=fedora with no quotes.
    local box
    box=$(sandbox)
    printf 'NAME="Fedora Linux"\nID=fedora\n' > "$box/os-release"
    assert_eq "$(os_release_id "$box/os-release")" "fedora" "unquoted ID"
}

test_os_release_id_reads_a_quoted_id() {
    # Debian and others write ID="debian". Both forms occur in the wild.
    local box
    box=$(sandbox)
    printf 'NAME="Debian GNU/Linux"\nID="debian"\n' > "$box/os-release"
    assert_eq "$(os_release_id "$box/os-release")" "debian" "quoted ID"
}

test_os_release_id_reports_unknown_without_an_id() {
    local box
    box=$(sandbox)
    printf 'NAME=Something\n' > "$box/os-release"
    assert_eq "$(os_release_id "$box/os-release")" "unknown" "no ID line"
}

test_os_release_id_reports_unknown_for_an_empty_id() {
    local box
    box=$(sandbox)
    printf 'ID=""\n' > "$box/os-release"
    assert_eq "$(os_release_id "$box/os-release")" "unknown" "empty ID"
}

test_os_release_id_reports_unknown_for_a_missing_file() {
    local box
    box=$(sandbox)
    assert_eq "$(os_release_id "$box/absent")" "unknown" "missing file"
}

test_os_release_id_does_not_leak_variables() {
    # os-release defines ID, NAME and VERSION. Sourcing it in the caller's
    # shell would clobber them, so it is sourced in a subshell.
    #
    # This test takes a fixture rather than relying on /etc/os-release, so it
    # genuinely exercises the sourcing path on macOS too. Asserting against
    # the real file would pass trivially on Darwin, where this code never runs.
    local box ID NAME VERSION
    box=$(sandbox)
    printf 'NAME="Fedora Linux"\nID=fedora\nVERSION=41\n' > "$box/os-release"
    ID="sentinel"
    NAME="sentinel"
    VERSION="sentinel"
    os_release_id "$box/os-release" >/dev/null
    assert_eq "$ID" "sentinel" "ID not leaked"
    assert_eq "$NAME" "sentinel" "NAME not leaked"
    assert_eq "$VERSION" "sentinel" "VERSION not leaked"
}

# --------------------------------------------------------------------------
# detect_platform()
# --------------------------------------------------------------------------

test_detect_platform_honours_the_override() {
    assert_eq "$(DOTFILES_PLATFORM=fedora detect_platform)" "fedora" "override"
}

test_detect_platform_trims_the_override() {
    # A value pasted from shell history can carry a trailing space. Tasks
    # downstream match it against a fixed list, where " fedora" matches
    # nothing and the failure would be reported far from its cause.
    assert_eq "$(DOTFILES_PLATFORM='  fedora  ' detect_platform)" "fedora" "trimmed"
}

test_detect_platform_ignores_a_whitespace_only_override() {
    # Whitespace-only is a typo, not a platform. It must fall through to real
    # detection rather than being used as the platform name.
    assert_eq "$(DOTFILES_PLATFORM='   ' detect_platform)" \
        "$(detect_platform)" "whitespace override ignored"
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
    expected=$(os_release_id /etc/os-release)
    assert_eq "$(detect_platform)" "$expected" "linux"
}

run_test test_os_release_id_reads_an_unquoted_id
run_test test_os_release_id_reads_a_quoted_id
run_test test_os_release_id_reports_unknown_without_an_id
run_test test_os_release_id_reports_unknown_for_an_empty_id
run_test test_os_release_id_reports_unknown_for_a_missing_file
run_test test_os_release_id_does_not_leak_variables
run_test test_detect_platform_honours_the_override
run_test test_detect_platform_trims_the_override
run_test test_detect_platform_ignores_a_whitespace_only_override
run_test test_detect_platform_reports_macos_on_darwin
run_test test_detect_platform_reads_os_release_id_on_linux

# --------------------------------------------------------------------------
# list_contains() and tool()
# --------------------------------------------------------------------------

test_list_contains_finds_a_word() {
    list_contains fedora "fedora macos"
    assert_ok $? "present"
}

test_list_contains_rejects_a_missing_word() {
    list_contains arch "fedora macos"
    assert_fails $? "absent"
}

test_list_contains_rejects_a_partial_match() {
    # "fedora" must not match inside "fedora-silverblue".
    list_contains fedora "fedora-silverblue"
    assert_fails $? "partial"
}

test_list_contains_handles_an_empty_list() {
    list_contains fedora ""
    assert_fails $? "empty"
}

test_tool_records_every_field() {
    manifest_reset
    tool btop --platforms "fedora macos" --config btop \
        --dnf "btop" --brew "btop"
    assert_eq "${#tool_names[@]}" "1" "one tool recorded"
    assert_eq "${tool_names[0]}" "btop" "name"
    assert_eq "${tool_platforms[0]}" "fedora macos" "platforms"
    assert_eq "${tool_config[0]}" "btop" "config"
    assert_eq "${tool_dnf[0]}" "btop" "dnf"
    assert_eq "${tool_brew[0]}" "btop" "brew"
    assert_eq "${tool_home[0]}" "" "home defaults empty"
    assert_eq "${tool_cask[0]}" "" "cask defaults empty"
    assert_eq "${tool_post[0]}" "" "post defaults empty"
}

test_tool_records_home_entries_and_post() {
    manifest_reset
    tool zsh --platforms "fedora macos" --home ".zshrc .zprofile .zsh" \
        --dnf "zsh" --post "echo done"
    assert_eq "${tool_home[0]}" ".zshrc .zprofile .zsh" "home"
    assert_eq "${tool_post[0]}" "echo done" "post"
    assert_eq "${tool_config[0]}" "" "config defaults empty"
}

test_tool_records_several_tools_in_order() {
    manifest_reset
    tool a --platforms fedora
    tool b --platforms macos
    assert_eq "${#tool_names[@]}" "2" "two tools"
    assert_eq "${tool_names[0]}" "a" "first"
    assert_eq "${tool_names[1]}" "b" "second"
}

test_tool_rejects_an_unknown_flag() {
    manifest_reset
    local out
    out=$(tool bad --platforms fedora --nonsense x 2>&1)
    assert_fails $? "unknown flag status"
    assert_contains "$out" "unknown option --nonsense" "unknown flag message"
}

test_tool_requires_platforms() {
    manifest_reset
    local out
    out=$(tool bad --config bad 2>&1)
    assert_fails $? "missing platforms status"
    assert_contains "$out" "--platforms is required" "missing platforms message"
}

test_tool_rejects_a_flag_with_no_value() {
    manifest_reset
    local out
    out=$(tool bad --platforms 2>&1)
    assert_fails $? "dangling flag status"
    assert_contains "$out" "--platforms needs a value" "dangling flag message"
}

test_list_contains_is_not_confused_by_a_glob_in_the_list() {
    # Splitting the list requires leaving it unquoted, which also enables
    # pathname expansion. Without `set -f` the list "fedora * macos" becomes
    # the filenames in the caller's directory, so the answer depends on where
    # the script was run from.
    local box status
    box=$(sandbox)
    : > "$box/decoy-one"
    : > "$box/decoy-two"

    ( cd "$box" || exit 1; list_contains '*' "fedora * macos" )
    status=$?
    assert_ok $status "a literal * in the list is found"

    ( cd "$box" || exit 1; list_contains decoy-one "fedora * macos" )
    status=$?
    assert_fails $status "a filename must not match through glob expansion"
}

test_tool_rejects_a_flag_shaped_value() {
    manifest_reset
    local out
    out=$(tool bad --platforms --config sway 2>&1)
    assert_fails $? "flag-shaped value status"
    assert_contains "$out" "is missing its value" "flag-shaped value message"
    assert_eq "${#tool_names[@]}" "0" "nothing recorded"
}

test_tool_rejects_a_duplicate_name() {
    manifest_reset
    tool dup --platforms fedora
    local out
    out=$(tool dup --platforms macos 2>&1)
    assert_fails $? "duplicate name status"
    assert_contains "$out" "declared twice" "duplicate name message"
    assert_eq "${#tool_names[@]}" "1" "duplicate not recorded"
}

run_test test_list_contains_finds_a_word
run_test test_list_contains_rejects_a_missing_word
run_test test_list_contains_rejects_a_partial_match
run_test test_list_contains_handles_an_empty_list
run_test test_tool_records_every_field
run_test test_tool_records_home_entries_and_post
run_test test_tool_records_several_tools_in_order
run_test test_tool_rejects_an_unknown_flag
run_test test_tool_requires_platforms
run_test test_tool_rejects_a_flag_with_no_value
run_test test_list_contains_is_not_confused_by_a_glob_in_the_list
run_test test_tool_rejects_a_flag_shaped_value
run_test test_tool_rejects_a_duplicate_name

# --------------------------------------------------------------------------
# link()
# --------------------------------------------------------------------------

test_link_creates_an_absolute_symlink() {
    local box
    box=$(sandbox)
    mkdir -p "$box/src" "$box/home"
    link "$box/src" "$box/home/target" >/dev/null
    if [ ! -L "$box/home/target" ]; then
        fail "no symlink created"
        return
    fi
    assert_eq "$(readlink "$box/home/target")" "$(resolve "$box/src")" "absolute target"
}

test_link_reports_ok_for_an_existing_correct_link() {
    local box out
    box=$(sandbox)
    mkdir -p "$box/src" "$box/home"
    link "$box/src" "$box/home/target" >/dev/null
    out=$(link "$box/src" "$box/home/target")
    assert_contains "$out" "ok" "second run reports ok"
}

test_link_leaves_an_existing_relative_link_alone() {
    # The Fedora machine already has relative links from the old script. They
    # resolve to the right place, so they must be reported ok, not recreated.
    local box out
    box=$(sandbox)
    mkdir -p "$box/src" "$box/home"
    ln -s -- "../src" "$box/home/target"
    out=$(link "$box/src" "$box/home/target")
    assert_contains "$out" "ok" "relative link reported ok"
    assert_eq "$(readlink "$box/home/target")" "../src" "relative link untouched"
}

test_link_backs_up_a_real_directory_in_the_way() {
    local box
    box=$(sandbox)
    mkdir -p "$box/src" "$box/home/target"
    : > "$box/home/target/keepme"
    link "$box/src" "$box/home/target" >/dev/null
    if [ ! -L "$box/home/target" ]; then
        fail "target is not a symlink after backup"
    fi
    if ! ls -d "$box/home/target.backup-"* >/dev/null 2>&1; then
        fail "no backup directory created"
        return
    fi
    if [ ! -f "$(ls -d "$box/home/target.backup-"*)/keepme" ]; then
        fail "backup did not preserve contents"
    fi
}

test_link_replaces_a_symlink_pointing_somewhere_else() {
    local box
    box=$(sandbox)
    mkdir -p "$box/src" "$box/other" "$box/home"
    ln -s -- "$box/other" "$box/home/target"
    link "$box/src" "$box/home/target" >/dev/null
    assert_eq "$(resolve "$box/home/target")" "$(resolve "$box/src")" "repointed"
}

test_link_creates_missing_parent_directories() {
    local box
    box=$(sandbox)
    mkdir -p "$box/src"
    link "$box/src" "$box/home/deep/target" >/dev/null
    if [ ! -L "$box/home/deep/target" ]; then
        fail "parent directories not created"
    fi
}

test_link_reports_ok_for_an_existing_file_link() {
    # home/.zshrc and home/.zprofile are files, not directories. This is the
    # case a resolve() that does not dereference symlinks gets wrong, silently
    # backing up and relinking a correct link on every run.
    local box out
    box=$(sandbox)
    mkdir -p "$box/repo" "$box/home"
    : > "$box/repo/.zshrc"
    link "$box/repo/.zshrc" "$box/home/.zshrc" >/dev/null
    out=$(link "$box/repo/.zshrc" "$box/home/.zshrc")
    assert_contains "$out" "ok" "file link reported ok on second run"
    if ls -d "$box/home/.zshrc.backup-"* >/dev/null 2>&1; then
        fail "a correct file link was backed up and relinked"
    fi
}

run_test test_link_creates_an_absolute_symlink
run_test test_link_reports_ok_for_an_existing_correct_link
run_test test_link_leaves_an_existing_relative_link_alone
run_test test_link_backs_up_a_real_directory_in_the_way
run_test test_link_replaces_a_symlink_pointing_somewhere_else
run_test test_link_creates_missing_parent_directories
run_test test_link_reports_ok_for_an_existing_file_link

printf '\n%d test(s), %d failure(s), %d skipped\n' \
    "$tests_run" "$tests_failed" "$tests_skipped"

# A mistyped filter would otherwise print "0 test(s), 0 failure(s)" and exit 0,
# which reads exactly like a pass.
if [ -n "$filter" ] && [ "$tests_run" = 0 ] && [ "$tests_skipped" = 0 ]; then
    printf 'No test matched filter [%s]\n' "$filter" >&2
    exit 1
fi

[ "$tests_failed" = 0 ]
