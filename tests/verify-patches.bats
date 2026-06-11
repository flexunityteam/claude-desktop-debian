#!/usr/bin/env bats
#
# verify-patches.bats
# Tests for scripts/verify-patches.sh — the build-time static grep
# that confirms patch markers (issue #559 D6 / PR #555, extended to
# all patch suites) are present in the patched asar tree.
#
# Both these tests and the verify script consume the marker list from
# scripts/patch-markers.tsv, so adding a marker there automatically
# expands the test matrix below.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
VERIFY_SH="$SCRIPT_DIR/../scripts/verify-patches.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Source the verify script in library mode and reuse its
	# parser, so a TSV format change can't desync the two consumers.
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/verify-patches.sh
	source "$VERIFY_SH"
	load_markers
}

teardown() {
	if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Build a fixture asar-contents tree containing every sample, written
# to the file each marker targets. If $1 is given, the marker with
# that name is omitted (used to drive the missing-marker negative
# tests). Echoes the staging dir (the parent of app.asar.contents/).
write_fixture_tree() {
	local omit="${1:-}"
	local staging="$TEST_TMP/staging"
	local root="$staging/app.asar.contents"
	rm -rf "$staging"
	local i target
	for i in "${!marker_names[@]}"; do
		target="$root/${marker_files[$i]}"
		mkdir -p "$(dirname "$target")"
		# Touch the target even when omitting the sample, so the
		# negative test exercises a pattern miss rather than a
		# missing file.
		: >> "$target"
		if [[ ${marker_names[$i]} != "$omit" ]]; then
			printf '%s\n' "${marker_samples[$i]}" >> "$target"
		fi
	done
	printf '%s\n' "$staging"
}

# Build a single-file fixture containing the samples of every marker
# that targets the default index.js (the legacy input shape).
write_fixture_file() {
	local fixture="$TEST_TMP/index.js"
	: > "$fixture"
	local i
	for i in "${!marker_names[@]}"; do
		if [[ ${marker_files[$i]} == "$default_target" ]]; then
			printf '%s\n' "${marker_samples[$i]}" >> "$fixture"
		fi
	done
	printf '%s\n' "$fixture"
}

# =============================================================================
# Marker file integrity
# =============================================================================

@test "markers file: every regex matches its sample" {
	local i
	for i in "${!marker_names[@]}"; do
		run grep -qP -- "${marker_patterns[$i]}" \
			<(printf '%s\n' "${marker_samples[$i]}")
		[[ "$status" -eq 0 ]] || {
			echo "regex did not match own sample: ${marker_names[$i]}"
			echo "pattern: ${marker_patterns[$i]}"
			echo "sample:  ${marker_samples[$i]}"
			return 1
		}
	done
}

@test "markers file: at least 20 markers loaded" {
	[[ "${#marker_names[@]}" -ge 20 ]] || {
		echo "expected >= 20 markers, got ${#marker_names[@]}"
		return 1
	}
}

@test "markers file: covers non-default target files" {
	local i non_default=0
	for i in "${!marker_files[@]}"; do
		if [[ ${marker_files[$i]} != "$default_target" ]]; then
			non_default=$((non_default + 1))
		fi
	done
	[[ "$non_default" -ge 4 ]] || {
		echo "expected >= 4 non-default-file markers, got $non_default"
		return 1
	}
}

# =============================================================================
# Positive path: full fixture tree passes
# =============================================================================

@test "verify: exits 0 when every marker present" {
	local staging
	staging="$(write_fixture_tree)"

	run "$VERIFY_SH" "$staging"
	[[ "$status" -eq 0 ]] || {
		echo 'verify rejected a fully-marked fixture tree'
		echo "$output"
		return 1
	}

	run grep -c 'OK ' <<< "$output"
	[[ "$output" -eq "${#marker_names[@]}" ]] || {
		echo "expected ${#marker_names[@]} OK lines, got: $output"
		return 1
	}
}

@test "verify: accepts the asar-contents dir itself as input" {
	local staging
	staging="$(write_fixture_tree)"

	run "$VERIFY_SH" "$staging/app.asar.contents"
	[[ "$status" -eq 0 ]] || {
		echo 'verify rejected asar-contents-shaped input'
		echo "$output"
		return 1
	}
}

# =============================================================================
# Negative path: per-marker missing fixture
# =============================================================================

@test "verify: exits 2 and names the missing marker (each)" {
	local name staging failures=0
	for name in "${marker_names[@]}"; do
		staging="$(write_fixture_tree "$name")"

		run "$VERIFY_SH" "$staging"
		if [[ "$status" -ne 2 ]]; then
			echo "missing $name should exit 2, got $status"
			echo "$output"
			failures=$((failures + 1))
		fi
		if ! grep -q "$name" <<< "$output"; then
			echo "missing $name not named in output"
			echo "$output"
			failures=$((failures + 1))
		fi
	done
	[[ "$failures" -eq 0 ]]
}

@test "verify: exits 2 when a marker's target file is absent" {
	local staging
	staging="$(write_fixture_tree)"
	# Remove a non-default target file entirely — should MISS with
	# the file named, not crash.
	local i removed=''
	for i in "${!marker_files[@]}"; do
		if [[ ${marker_files[$i]} != "$default_target" ]]; then
			rm -f "$staging/app.asar.contents/${marker_files[$i]}"
			removed="${marker_files[$i]}"
			break
		fi
	done
	[[ -n "$removed" ]] || skip 'no non-default-file markers in TSV'

	run "$VERIFY_SH" "$staging"
	[[ "$status" -eq 2 ]]
	[[ "$output" == *'target file not found'* ]]
}

# =============================================================================
# Single-file input (fixture/debug mode)
# =============================================================================

@test "verify: single-file input checks index.js markers, skips others" {
	local fixture
	fixture="$(write_fixture_file)"

	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 0 ]] || {
		echo 'verify rejected a fully-marked single-file fixture'
		echo "$output"
		return 1
	}

	# Every non-default-file marker must be reported as SKIP, not OK.
	local i
	for i in "${!marker_names[@]}"; do
		if [[ ${marker_files[$i]} != "$default_target" ]]; then
			grep -q "SKIP ${marker_names[$i]}" <<< "$output" || {
				echo "expected SKIP for ${marker_names[$i]}"
				echo "$output"
				return 1
			}
		fi
	done
}

# =============================================================================
# Input shapes
# =============================================================================

@test "verify: rejects missing path with exit 1" {
	run "$VERIFY_SH" "$TEST_TMP/does-not-exist.js"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'not found'* ]]
}

@test "verify: rejects directory without expected layout" {
	mkdir -p "$TEST_TMP/empty"
	run "$VERIFY_SH" "$TEST_TMP/empty"
	[[ "$status" -eq 1 ]]
}

@test "verify: prints usage on no args and exits 1" {
	run "$VERIFY_SH"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'Usage:'* ]]
}

@test "verify: --help prints usage and exits 0" {
	run "$VERIFY_SH" --help
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'Usage:'* ]]
}
