#!/usr/bin/env bash
#
# verify-patches.sh
#
# Static-greps a patched asar tree for the patch markers defined in
# a TSV (defaults to scripts/patch-markers.tsv). Exits non-zero on
# any miss and names the missing markers in the output.
#
# Defends against silent half-patched asars (issue #559 D6, PR #555).
# Covers every patch suite — cowork, tray, quick-window, claude-code,
# org-plugins, config guards, the WCO shim in mainView.js, and the
# frame-fix wrapper wiring — via an optional per-marker target file
# column in the TSV (empty = .vite/build/index.js).
#
# Usage:
#     verify-patches.sh <path> [markers-tsv]
#
# <path> may be:
#   * an .asar archive (extracted on the fly via npx @electron/asar)
#   * a directory containing app.asar.contents/
#   * a directory that itself is an asar-contents tree
#     (contains .vite/build/index.js)
#   * a JavaScript file — fixture/debug mode: only markers targeting
#     the default index.js are checked; others are reported as SKIP
#
# Exit codes:
#   0  — every applicable marker present.
#   1  — usage error or input not found.
#   2  — one or more markers missing (named on stderr).
#

set -u
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_markers_tsv="$script_dir/patch-markers.tsv"
markers_tsv="$default_markers_tsv"

# Target file used when a TSV row omits the file column.
default_target='.vite/build/index.js'

usage() {
	cat <<-EOF >&2
		Usage: $(basename "$0") <path> [markers-tsv]

		<path> may be an .asar archive, a directory containing
		app.asar.contents/, a directory that itself is an
		asar-contents tree, or a single .js file (fixture mode —
		markers targeting other files are skipped). The script
		greps for patch markers and exits non-zero if any are
		missing.

		[markers-tsv] overrides the default TSV so the same script
		can verify other patch sets.
	EOF
}

# Parse the marker TSV into four parallel arrays. Skips comments
# and blank lines. The optional 4th column names the target file
# relative to the asar root; empty means $default_target. Used by
# both the verify path here and by the BATS test, which sources
# this script (see _is_sourced below) to share parsing and avoid
# drift between the two consumers.
load_markers() {
	marker_names=()
	marker_patterns=()
	marker_samples=()
	marker_files=()

	if [[ ! -f $markers_tsv ]]; then
		echo "verify-patches: marker file not found:" \
			"$markers_tsv" >&2
		return 1
	fi

	local name pattern sample file
	while IFS=$'\t' read -r name pattern sample file; do
		[[ -z $name || $name == '#'* ]] && continue
		if [[ -z ${pattern:-} || -z ${sample:-} ]]; then
			echo "verify-patches: malformed row '$name'" \
				'in markers file' >&2
			return 1
		fi
		marker_names+=("$name")
		marker_patterns+=("$pattern")
		marker_samples+=("$sample")
		marker_files+=("${file:-$default_target}")
	done < "$markers_tsv"

	if [[ ${#marker_names[@]} -eq 0 ]]; then
		echo 'verify-patches: no markers loaded' >&2
		return 1
	fi
}

# Resolve the input path to a scan target. Sets:
#   scan_mode — 'root' (directory tree) or 'file' (single file)
#   scan_path — the root directory or the single file
# For .asar inputs, extracts to a temp dir. The caller cleans up
# via cleanup_tmp.
tmp_extract_dir=''
cleanup_tmp() {
	if [[ -n $tmp_extract_dir && -d $tmp_extract_dir ]]; then
		rm -rf "$tmp_extract_dir"
	fi
}
trap cleanup_tmp EXIT

resolve_scan_target() {
	local input="$1"
	scan_mode=''
	scan_path=''

	if [[ ! -e $input ]]; then
		echo "verify-patches: not found: $input" >&2
		return 1
	fi

	if [[ -d $input ]]; then
		if [[ -d "$input/app.asar.contents" ]]; then
			scan_mode='root'
			scan_path="$input/app.asar.contents"
			return 0
		fi
		if [[ -f "$input/$default_target" ]]; then
			scan_mode='root'
			scan_path="$input"
			return 0
		fi
		echo "verify-patches: directory contains neither" \
			"app.asar.contents/ nor $default_target: $input" >&2
		return 1
	fi

	if [[ $input == *.asar ]]; then
		if ! command -v npx > /dev/null 2>&1; then
			echo 'verify-patches: npx not found; install Node.js' \
				'or pre-extract the asar' >&2
			return 1
		fi
		tmp_extract_dir="$(mktemp -d)"
		if ! npx --yes @electron/asar extract "$input" \
			"$tmp_extract_dir" > /dev/null 2>&1; then
			echo "verify-patches: asar extraction failed:" \
				"$input" >&2
			return 1
		fi
		if [[ ! -f "$tmp_extract_dir/$default_target" ]]; then
			echo 'verify-patches: extracted asar lacks' \
				"$default_target" >&2
			return 1
		fi
		scan_mode='root'
		scan_path="$tmp_extract_dir"
		return 0
	fi

	# Treat as a single file (fixture/debug mode) — only markers
	# targeting the default index.js apply.
	scan_mode='file'
	scan_path="$input"
}

main() {
	if [[ $# -lt 1 || $# -gt 2 ]]; then
		usage
		return 1
	fi

	case "$1" in
		-h | --help)
			usage
			return 0
			;;
	esac

	if [[ $# -eq 2 ]]; then
		markers_tsv="$2"
	fi

	if ! resolve_scan_target "$1"; then
		return 1
	fi

	if ! load_markers; then
		return 1
	fi

	echo "Verifying patch markers in: $scan_path ($scan_mode mode)"
	echo "Marker source: $markers_tsv"

	local i target missing_names=() skipped=0
	for i in "${!marker_names[@]}"; do
		if [[ $scan_mode == 'file' ]]; then
			if [[ ${marker_files[$i]} != "$default_target" ]]; then
				printf '  SKIP %s (targets %s; single-file input)\n' \
					"${marker_names[$i]}" "${marker_files[$i]}"
				skipped=$((skipped + 1))
				continue
			fi
			target="$scan_path"
		else
			target="$scan_path/${marker_files[$i]}"
			if [[ ! -f $target ]]; then
				printf '  MISS %s (target file not found: %s)\n' \
					"${marker_names[$i]}" "${marker_files[$i]}" >&2
				missing_names+=("${marker_names[$i]}")
				continue
			fi
		fi

		if grep -qP -- "${marker_patterns[$i]}" "$target"; then
			printf '  OK   %s\n' "${marker_names[$i]}"
		else
			printf '  MISS %s\n' "${marker_names[$i]}" >&2
			missing_names+=("${marker_names[$i]}")
		fi
	done

	if [[ ${#missing_names[@]} -gt 0 ]]; then
		local joined
		joined="$(IFS=','; printf '%s' "${missing_names[*]}")"
		printf '\nverify-patches: %d/%d markers missing: %s\n' \
			"${#missing_names[@]}" "${#marker_names[@]}" "$joined" >&2
		return 2
	fi

	printf '\nAll %d applicable patch markers present (%d skipped).\n' \
		"$(( ${#marker_names[@]} - skipped ))" "$skipped"
	return 0
}

# Library mode: when sourced (BATS test), expose load_markers and
# the markers_tsv path without running main.
_is_sourced() {
	[[ ${BASH_SOURCE[0]} != "${0}" ]]
}

if ! _is_sourced; then
	main "$@"
fi
