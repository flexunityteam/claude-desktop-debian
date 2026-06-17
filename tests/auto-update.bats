#!/usr/bin/env bats
#
# auto-update.bats
# Tests for the version logic in scripts/auto-update.sh
#
# auto-update.sh reuses doctor.sh's output helpers, so both are sourced.
# The probes (_au_installed_version, _au_latest_tag, _au_notify, …) are
# standalone functions so these tests can shadow them and drive
# run_auto_update deterministically — no dpkg, network, or build needed.
# The actual build/install path (_au_perform_update) is shadowed out;
# it's exercised live, not in CI.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# shellcheck source=scripts/doctor.sh
	source "$SCRIPT_DIR/../scripts/doctor.sh"
	# shellcheck source=scripts/auto-update.sh
	source "$SCRIPT_DIR/../scripts/auto-update.sh"

	# Quiet, side-effect-free notifications.
	_au_notify() { echo "NOTIFY[$1] $2 — $3"; }
	# Never actually build/install in tests; record the call instead.
	_au_perform_update() { echo "PERFORM $2 ($1)"; return 0; }
}

teardown() {
	[[ -n "$TEST_TMP" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}

# Healthy default: dpkg-installed older version, newer upstream tag.
# eval bakes the literals into the function bodies — a plain definition
# would close over _stub_versions' locals, which vanish on return.
_stub_versions() {
	eval "_au_installed_version() { echo '$1'; }"
	eval "_au_latest_tag() { echo '$2'; }"
}

# =============================================================================
# tag parsing
# =============================================================================

@test "tag: extracts claude version from vREPO+claude tag" {
	[[ $(_au_tag_claude_version 'v2.0.20+claude1.13576.0') == '1.13576.0' ]]
	[[ $(_au_tag_claude_version 'v2.0.19+claude1.11847.5') == '1.11847.5' ]]
}

@test "tag: empty for a tag without a +claude segment" {
	[[ -z $(_au_tag_claude_version 'v2.0.20') ]]
}

# =============================================================================
# version comparison (dpkg semantics)
# =============================================================================

@test "version: newer is detected across all numeric fields" {
	_au_version_newer '1.13576.0' '1.11847.5'
	_au_version_newer '1.11847.6' '1.11847.5'
	run _au_version_newer '1.11847.5' '1.11847.5'
	[[ $status -ne 0 ]]
	run _au_version_newer '1.11847.5' '1.13576.0'
	[[ $status -ne 0 ]]
}

# =============================================================================
# argument handling
# =============================================================================

@test "update: --help exits 0 with usage" {
	run run_auto_update --help
	[[ $status -eq 0 ]]
	[[ $output == *'Usage: claude-desktop --update'* ]]
}

@test "update: unknown option exits 2" {
	run run_auto_update --frob
	[[ $status -eq 2 ]]
	[[ $output == *'unknown option'* ]]
}

@test "update: aborts when latest tag can't be resolved" {
	_au_installed_version() { echo '1.11847.5'; }
	_au_latest_tag() { echo ''; }
	run run_auto_update --check
	[[ $status -eq 1 ]]
	[[ $output == *'Could not determine the latest'* ]]
}

# =============================================================================
# --check
# =============================================================================

@test "check: exits 10 and notifies when behind" {
	_stub_versions '1.11847.5' 'v2.0.20+claude1.13576.0'
	run run_auto_update --check
	[[ $status -eq 10 ]]
	[[ $output == *'1.13576.0'* ]]
	[[ $output == *'NOTIFY'* ]]
}

@test "check: exits 0 when already current" {
	_stub_versions '1.13576.0' 'v2.0.20+claude1.13576.0'
	run run_auto_update --check
	[[ $status -eq 0 ]]
	[[ $output == *'Already up to date'* ]]
}

# =============================================================================
# not dpkg-installed
# =============================================================================

@test "update: no-op when not installed via dpkg" {
	_au_installed_version() { echo ''; }
	_au_latest_tag() { echo 'v2.0.20+claude1.13576.0'; }
	run run_auto_update
	[[ $status -eq 0 ]]
	[[ $output == *'not installed via dpkg'* ]]
}

# =============================================================================
# --dry-run
# =============================================================================

@test "dry-run: prints the plan, never builds" {
	_stub_versions '1.11847.5' 'v2.0.20+claude1.13576.0'
	run run_auto_update --dry-run
	[[ $status -eq 0 ]]
	[[ $output == *'Would update 1.11847.5 -> 1.13576.0'* ]]
	[[ $output != *'PERFORM'* ]]
}

@test "dry-run: reports up to date when current" {
	_stub_versions '1.13576.0' 'v2.0.20+claude1.13576.0'
	run run_auto_update --dry-run
	[[ $status -eq 0 ]]
	[[ $output == *'Already up to date'* ]]
}

# =============================================================================
# default run + --force dispatch to _au_perform_update
# =============================================================================

@test "run: dispatches to perform_update when behind" {
	_stub_versions '1.11847.5' 'v2.0.20+claude1.13576.0'
	run run_auto_update
	[[ $status -eq 0 ]]
	[[ $output == *'PERFORM 1.13576.0 (v2.0.20+claude1.13576.0)'* ]]
}

@test "run: no build when already current" {
	_stub_versions '1.13576.0' 'v2.0.20+claude1.13576.0'
	run run_auto_update
	[[ $status -eq 0 ]]
	[[ $output != *'PERFORM'* ]]
}

@test "force: rebuilds even when already current" {
	_stub_versions '1.13576.0' 'v2.0.20+claude1.13576.0'
	run run_auto_update --force
	[[ $status -eq 0 ]]
	[[ $output == *'PERFORM 1.13576.0'* ]]
}

# =============================================================================
# setup guard
# =============================================================================

@test "setup: unknown option exits 2" {
	run run_setup_auto_update --frob
	[[ $status -eq 2 ]]
	[[ $output == *'unknown option'* ]]
}

@test "setup: --help exits 0 with usage" {
	run run_setup_auto_update --help
	[[ $status -eq 0 ]]
	[[ $output == *'Usage: claude-desktop --setup-auto-update'* ]]
}
