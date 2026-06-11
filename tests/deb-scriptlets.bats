#!/usr/bin/env bats
#
# deb-scriptlets.bats
# Tests for the deb postinst/postrm generators in
# scripts/packaging/deb-scriptlets.sh
#
# The generators accept path arguments precisely so this suite can
# bake temp paths into the scriptlets and execute them as a regular
# user: a fake apparmor.d dir, a fake userns kernel knob file, and a
# fake install root. apparmor_parser / chown / chmod /
# update-desktop-database are PATH stubs that log their argv, so the
# assertions cover both filesystem effects and tool invocations.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

PKG='claude-desktop'

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# shellcheck source=scripts/packaging/deb-scriptlets.sh
	source "$SCRIPT_DIR/../scripts/packaging/deb-scriptlets.sh"

	APPARMOR_DIR="$TEST_TMP/apparmor.d"
	USERNS_KNOB="$TEST_TMP/userns_knob"
	USR_LIB="$TEST_TMP/usr/lib/$PKG"
	TOOL_LOG="$TEST_TMP/tools.log"
	mkdir -p "$APPARMOR_DIR" "$USR_LIB"

	# PATH stubs that record invocations. chown/chmod must be shadowed
	# (the sandbox block calls them on root-owned paths); everything
	# else in the scriptlets (grep, mkdir, rm, cat) runs for real.
	# ORIG_PATH lets _generate run with the real chmod so the
	# generators' own `chmod 755` isn't captured by the stub.
	ORIG_PATH="$PATH"
	mkdir -p "$TEST_TMP/bin"
	local tool
	for tool in apparmor_parser update-desktop-database chown chmod; do
		printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' \
			"$tool" "$TOOL_LOG" > "$TEST_TMP/bin/$tool"
		chmod +x "$TEST_TMP/bin/$tool"
	done
	PATH="$TEST_TMP/bin:$PATH"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Generate both scriptlets against the temp prefix. Runs with the
# original PATH: generation is build-time work and must not hit (or
# pollute the log of) the runtime tool stubs.
_generate() {
	local stubbed_path="$PATH"
	PATH="$ORIG_PATH"
	write_deb_postinst "$TEST_TMP/postinst" "$PKG" \
		"$USR_LIB" "$APPARMOR_DIR" "$USERNS_KNOB"
	write_deb_postrm "$TEST_TMP/postrm" "$PKG" "$APPARMOR_DIR"
	PATH="$stubbed_path"
}

# Create the fake chrome-sandbox binary inside the install root.
_make_sandbox() {
	mkdir -p "$USR_LIB/node_modules/electron/dist"
	touch "$USR_LIB/node_modules/electron/dist/chrome-sandbox"
}

# =============================================================================
# generation basics
# =============================================================================

@test "scriptlets: generated files are executable POSIX sh" {
	_generate
	[[ -x "$TEST_TMP/postinst" ]]
	[[ -x "$TEST_TMP/postrm" ]]
	head -1 "$TEST_TMP/postinst" | grep -qx '#!/bin/sh'
	head -1 "$TEST_TMP/postrm" | grep -qx '#!/bin/sh'
	sh -n "$TEST_TMP/postinst"
	sh -n "$TEST_TMP/postrm"
}

@test "scriptlets: default args bake the production paths" {
	write_deb_postinst "$TEST_TMP/postinst" "$PKG"
	write_deb_postrm "$TEST_TMP/postrm" "$PKG"
	grep -q "/usr/lib/$PKG/node_modules/electron/dist/chrome-sandbox" \
		"$TEST_TMP/postinst"
	grep -q "/etc/apparmor.d/$PKG" "$TEST_TMP/postinst"
	grep -q '/proc/sys/kernel/apparmor_restrict_unprivileged_userns' \
		"$TEST_TMP/postinst"
	grep -q "/etc/apparmor.d/$PKG" "$TEST_TMP/postrm"
	grep -q "/etc/apparmor.d/${PKG}-bwrap" "$TEST_TMP/postrm"
}

# =============================================================================
# postinst: chrome-sandbox permissions
# =============================================================================

@test "postinst: sets 4755 root:root on an existing chrome-sandbox" {
	_generate
	_make_sandbox
	run sh "$TEST_TMP/postinst" configure
	[[ $status -eq 0 ]]
	grep -q 'chown root:root .*chrome-sandbox' "$TOOL_LOG"
	grep -q 'chmod 4755 .*chrome-sandbox' "$TOOL_LOG"
}

@test "postinst: warns but exits 0 when chrome-sandbox is missing" {
	_generate
	run sh "$TEST_TMP/postinst" configure
	[[ $status -eq 0 ]]
	[[ $output == *'chrome-sandbox binary not found'* ]]
}

# =============================================================================
# postinst: AppArmor gating
# =============================================================================

@test "postinst: no userns knob => no AppArmor profiles written" {
	_generate
	_make_sandbox
	rm -f "$USERNS_KNOB"
	run sh "$TEST_TMP/postinst" configure
	[[ $status -eq 0 ]]
	[[ ! -e "$APPARMOR_DIR/$PKG" ]]
	[[ ! -e "$APPARMOR_DIR/${PKG}-bwrap" ]]
}

@test "postinst: knob present => writes and loads both profiles" {
	_generate
	_make_sandbox
	touch "$USERNS_KNOB"
	run sh "$TEST_TMP/postinst" configure
	[[ $status -eq 0 ]]
	[[ -f "$APPARMOR_DIR/$PKG" ]]
	[[ -f "$APPARMOR_DIR/${PKG}-bwrap" ]]
	grep -q "managed by the $PKG package" "$APPARMOR_DIR/$PKG"
	grep -q 'userns,' "$APPARMOR_DIR/$PKG"
	grep -q "profile ${PKG}-bwrap /usr/bin/bwrap" "$APPARMOR_DIR/${PKG}-bwrap"
	# Both -Q (syntax check) and -r (load) must run for each profile.
	grep -q "apparmor_parser -Q $APPARMOR_DIR/$PKG" "$TOOL_LOG"
	grep -q "apparmor_parser -r $APPARMOR_DIR/$PKG" "$TOOL_LOG"
	grep -q "apparmor_parser -Q $APPARMOR_DIR/${PKG}-bwrap" "$TOOL_LOG"
	grep -q "apparmor_parser -r $APPARMOR_DIR/${PKG}-bwrap" "$TOOL_LOG"
}

@test "postinst: profile attachment path follows the install root" {
	_generate
	_make_sandbox
	touch "$USERNS_KNOB"
	run sh "$TEST_TMP/postinst" configure
	grep -q "profile $PKG $USR_LIB/node_modules/electron/dist/electron" \
		"$APPARMOR_DIR/$PKG"
}

@test "postinst: preserves a hand-edited profile (no marker header)" {
	_generate
	_make_sandbox
	touch "$USERNS_KNOB"
	echo '# my local hand-made profile' > "$APPARMOR_DIR/$PKG"
	run sh "$TEST_TMP/postinst" configure
	[[ $status -eq 0 ]]
	[[ $output == *'Preserving locally modified'* ]]
	[[ $(cat "$APPARMOR_DIR/$PKG") == '# my local hand-made profile' ]]
	# Still reloads the admin's profile so it stays active.
	grep -q "apparmor_parser -r $APPARMOR_DIR/$PKG" "$TOOL_LOG"
}

@test "postinst: overwrites a stale profile that carries our marker" {
	_generate
	_make_sandbox
	touch "$USERNS_KNOB"
	printf '# managed by the %s package (old contents)\n' "$PKG" \
		> "$APPARMOR_DIR/$PKG"
	run sh "$TEST_TMP/postinst" configure
	[[ $status -eq 0 ]]
	grep -q 'userns,' "$APPARMOR_DIR/$PKG"
	! grep -q 'old contents' "$APPARMOR_DIR/$PKG"
}

@test "postinst: removes the profile when apparmor_parser -Q rejects it" {
	_generate
	_make_sandbox
	touch "$USERNS_KNOB"
	# Parser that fails -Q (old AppArmor without userns support).
	printf '#!/bin/sh\n[ "$1" = -Q ] && exit 1\nexit 0\n' \
		> "$TEST_TMP/bin/apparmor_parser"
	chmod +x "$TEST_TMP/bin/apparmor_parser"
	run sh "$TEST_TMP/postinst" configure
	[[ $status -eq 0 ]]
	[[ $output == *'does not support the userns rule'* ]]
	[[ ! -e "$APPARMOR_DIR/$PKG" ]]
	[[ ! -e "$APPARMOR_DIR/${PKG}-bwrap" ]]
}

@test "postinst: defers to an existing foreign bwrap profile" {
	_generate
	_make_sandbox
	touch "$USERNS_KNOB"
	printf 'profile bwrap-userns-restrict /usr/bin/bwrap {\n}\n' \
		> "$APPARMOR_DIR/bwrap-userns-restrict"
	run sh "$TEST_TMP/postinst" configure
	[[ $status -eq 0 ]]
	[[ $output == *'already covers /usr/bin/bwrap'* ]]
	[[ ! -e "$APPARMOR_DIR/${PKG}-bwrap" ]]
	# The Electron profile is unaffected by the bwrap deferral.
	[[ -f "$APPARMOR_DIR/$PKG" ]]
}

@test "postinst: idempotent — second run leaves identical profiles" {
	_generate
	_make_sandbox
	touch "$USERNS_KNOB"
	sh "$TEST_TMP/postinst" configure > /dev/null
	cp "$APPARMOR_DIR/$PKG" "$TEST_TMP/first-run"
	run sh "$TEST_TMP/postinst" configure
	[[ $status -eq 0 ]]
	diff -q "$APPARMOR_DIR/$PKG" "$TEST_TMP/first-run"
}

# =============================================================================
# postrm: remove / purge / upgrade semantics
# =============================================================================

# Lay down both profiles as a prior postinst would have.
_install_profiles() {
	printf '# managed by the %s package\n' "$PKG" > "$APPARMOR_DIR/$PKG"
	printf '# managed by the %s package\n' "$PKG" > "$APPARMOR_DIR/${PKG}-bwrap"
}

@test "postrm remove: unloads profiles but keeps the files" {
	_generate
	_install_profiles
	run sh "$TEST_TMP/postrm" remove
	[[ $status -eq 0 ]]
	grep -q "apparmor_parser -R $APPARMOR_DIR/$PKG" "$TOOL_LOG"
	grep -q "apparmor_parser -R $APPARMOR_DIR/${PKG}-bwrap" "$TOOL_LOG"
	[[ -f "$APPARMOR_DIR/$PKG" ]]
	[[ -f "$APPARMOR_DIR/${PKG}-bwrap" ]]
}

@test "postrm purge: unloads and deletes both profiles" {
	_generate
	_install_profiles
	run sh "$TEST_TMP/postrm" purge
	[[ $status -eq 0 ]]
	[[ ! -e "$APPARMOR_DIR/$PKG" ]]
	[[ ! -e "$APPARMOR_DIR/${PKG}-bwrap" ]]
}

@test "postrm upgrade: touches nothing" {
	_generate
	_install_profiles
	run sh "$TEST_TMP/postrm" upgrade
	[[ $status -eq 0 ]]
	[[ ! -e "$TOOL_LOG" ]]
	[[ -f "$APPARMOR_DIR/$PKG" ]]
	[[ -f "$APPARMOR_DIR/${PKG}-bwrap" ]]
}

@test "postrm remove: exits 0 when no profiles exist" {
	_generate
	run sh "$TEST_TMP/postrm" remove
	[[ $status -eq 0 ]]
}
