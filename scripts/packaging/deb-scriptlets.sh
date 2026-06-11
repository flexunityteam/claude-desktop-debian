# shellcheck shell=bash
#===============================================================================
# Debian Maintainer Scriptlet Generators
#
# Sourced by: scripts/packaging/deb.sh (build time only — nothing here
# ships in the package; the *output* of these functions does).
#
# The postinst/postrm bodies used to live as heredocs inside deb.sh,
# which made their logic (AppArmor profile management, marker-based
# preservation, purge-vs-remove semantics) impossible to unit-test
# without a root dpkg transaction. As generator functions the same
# bodies can be written against a temp prefix and executed under BATS
# with stubbed tools (see tests/deb-scriptlets.bats).
#
# The path arguments exist for the tests; production callers pass only
# the output path and package name, and the defaults bake the real
# system paths into the generated script — the shipped scriptlets keep
# the exact logic of the old inline heredocs.
#===============================================================================

# Generate the postinst script.
#   $1 = output path
#   $2 = package name
#   $3 = installed app root      (default /usr/lib/<package>)
#   $4 = apparmor.d directory    (default /etc/apparmor.d)
#   $5 = userns kernel knob path (default /proc/sys/kernel/...)
write_deb_postinst() {
	local out="$1"
	local package_name="$2"
	local usr_lib_dir="${3:-/usr/lib/$package_name}"
	local apparmor_dir="${4:-/etc/apparmor.d}"
	local userns_knob="${5:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}"

	cat > "$out" << EOF
#!/bin/sh
set -e

# Update desktop database for MIME types
echo "Updating desktop database..."
update-desktop-database /usr/share/applications > /dev/null 2>&1 || true

# Set correct permissions for chrome-sandbox if electron is installed globally
# or locally packaged
echo "Setting chrome-sandbox permissions..."
SANDBOX_PATH=""
# Electron is always packaged locally now, so only check the local path.
LOCAL_SANDBOX_PATH="$usr_lib_dir/node_modules/electron/dist/chrome-sandbox"
if [ -f "\$LOCAL_SANDBOX_PATH" ]; then
    SANDBOX_PATH="\$LOCAL_SANDBOX_PATH"
fi

if [ -n "\$SANDBOX_PATH" ] && [ -f "\$SANDBOX_PATH" ]; then
    echo "Found chrome-sandbox at: \$SANDBOX_PATH"
    chown root:root "\$SANDBOX_PATH" || echo "Warning: Failed to chown chrome-sandbox"
    chmod 4755 "\$SANDBOX_PATH" || echo "Warning: Failed to chmod chrome-sandbox"
    echo "Permissions set for \$SANDBOX_PATH"
else
    echo "Warning: chrome-sandbox binary not found in local package at \$LOCAL_SANDBOX_PATH. Sandbox may not function correctly."
fi

# --- AppArmor profile for Chromium's user-namespace sandbox ---
# Ubuntu 24.04+ sets kernel.apparmor_restrict_unprivileged_userns=1, which
# blocks the unprivileged user namespaces Chromium's sandbox relies on,
# crashing the app on launch with a sandbox/.../credentials.cc FATAL.
# Grant userns to our Electron binary via a scoped AppArmor profile, exactly
# as the google-chrome, code, and slack packages do. Gate on the kernel knob
# (not just apparmor_parser): only Ubuntu-family systems impose the
# restriction, so on stock Debian/others the knob is absent and we skip the
# profile entirely rather than installing one they never need. The knob may
# read 0 now and flip to 1 later, so existence — not value — is the gate.
APPARMOR_PROFILE="$apparmor_dir/$package_name"
if command -v apparmor_parser >/dev/null 2>&1 \
    && [ -e "$userns_knob" ]; then
    echo "Configuring AppArmor profile for Chromium sandbox..."
    # Writing the profile is best-effort: a read-only or atypical /etc must
    # never abort the install (this postinst runs under set -e). Keeping the
    # grep / mkdir + heredoc in the if/elif conditions exempts them from
    # errexit. Debian Policy 10.7.3: a profile without our marker header was
    # hand-created or hand-edited by the admin — preserve it, never overwrite.
    if [ -e "\$APPARMOR_PROFILE" ] \
        && ! grep -qF "managed by the $package_name package" \
            "\$APPARMOR_PROFILE" 2>/dev/null; then
        echo "Preserving locally modified \$APPARMOR_PROFILE (no marker header)"
        apparmor_parser -r "\$APPARMOR_PROFILE" >/dev/null 2>&1 || true
    elif mkdir -p "$apparmor_dir" 2>/dev/null && cat > "\$APPARMOR_PROFILE" <<'APPARMOR_EOF'
# This profile is managed by the $package_name package (postinst); direct
# edits will be overwritten on upgrade. Put local changes in
# /etc/apparmor.d/local/$package_name instead.
abi <abi/4.0>,
include <tunables/global>

profile $package_name $usr_lib_dir/node_modules/electron/dist/electron flags=(unconfined) {
    userns,

    include if exists <local/$package_name>
}
APPARMOR_EOF
    then
        if apparmor_parser -Q "\$APPARMOR_PROFILE" >/dev/null 2>&1; then
            apparmor_parser -r "\$APPARMOR_PROFILE" >/dev/null 2>&1 || echo "Note: AppArmor profile staged but not loaded now; it will apply on the next AppArmor reload or reboot."
            echo "AppArmor profile installed at \$APPARMOR_PROFILE"
        else
            rm -f "\$APPARMOR_PROFILE"
            echo "AppArmor on this system does not support the userns rule; skipping profile (not required here)."
        fi
    else
        # A failed write may leave a truncated profile behind; clear it.
        # The || true is mandatory: this branch is errexit-live, and a bare
        # rm fails the upgrade on a read-only /etc.
        rm -f "\$APPARMOR_PROFILE" 2>/dev/null || true
        echo "Warning: could not write \$APPARMOR_PROFILE; skipping AppArmor profile."
    fi
fi

# --- AppArmor profile for the Cowork bwrap sandbox helper ---
# Cowork's "bwrap backend" runs the agent's Claude Code process inside a
# bubblewrap sandbox, which itself needs unprivileged user namespaces — the
# same thing Ubuntu 24.04+ blocks (apparmor_restrict_unprivileged_userns=1).
# bwrap is a SEPARATE binary from the Electron app, so the claude-desktop
# profile above (which scopes the Electron binary) does not cover it; it
# needs its own profile on /usr/bin/bwrap. Without this, Cowork silently
# falls back to host-direct (no isolation).
#
# Gate on the kernel knob, exactly like the Electron block above: only a
# kernel that can enforce the restriction exposes the knob, and a userspace
# parser that merely accepts the userns rule (AppArmor 4) is not
# enforcement — without the knob the profile is dead weight on a binary
# this package does not own. There is deliberately no [ -x /usr/bin/bwrap ]
# gate: a profile attaching to a nonexistent binary is inert, and dpkg
# gives Recommends no ordering edge, so gating on the binary races a
# same-transaction bubblewrap install. Static checks only: postinst runs as
# root, which is exempt from the unprivileged-userns restriction, so a
# behavioral bwrap probe here would falsely pass — the behavioral probe
# lives in 'claude-desktop --doctor' instead (runs as the user).
BWRAP_PROFILE="$apparmor_dir/${package_name}-bwrap"
if command -v apparmor_parser >/dev/null 2>&1 \
    && [ -e "$userns_knob" ]; then
    echo "Configuring AppArmor profile for the Cowork bwrap sandbox..."
    # Writing the profile is best-effort: a read-only or atypical /etc must
    # never abort the install (this postinst runs under set -e). Keeping the
    # grep / mkdir + heredoc in the if/elif conditions exempts them from
    # errexit. Debian Policy 10.7.3: a profile without our marker header was
    # hand-created or hand-edited by the admin — preserve it, never overwrite.
    if [ -e "\$BWRAP_PROFILE" ] \
        && ! grep -qF "managed by the $package_name package" \
            "\$BWRAP_PROFILE" 2>/dev/null; then
        echo "Preserving locally modified \$BWRAP_PROFILE (no marker header)"
        apparmor_parser -r "\$BWRAP_PROFILE" >/dev/null 2>&1 || true
    elif grep -rl '/usr/bin/bwrap' "$apparmor_dir/" 2>/dev/null \
        | grep -vxF "\$BWRAP_PROFILE" | grep -q .; then
        # Another profile already attaches to /usr/bin/bwrap — a hand-made
        # /etc/apparmor.d/bwrap, apparmor-profiles' bwrap-userns-restrict,
        # or any other filename. Identical attachment strings have no
        # specificity tiebreak, and shadowing a restrictive profile with our
        # unconfined-mode one would silently undo distro hardening, so defer
        # to the existing profile. (A false grep hit in a comment fails
        # safe: we merely skip our profile.)
        echo "An existing AppArmor profile already covers /usr/bin/bwrap; leaving it in charge."
    elif mkdir -p "$apparmor_dir" 2>/dev/null && cat > "\$BWRAP_PROFILE" <<'BWRAP_APPARMOR_EOF'
# This profile is managed by the $package_name package (postinst); direct
# edits will be overwritten on upgrade. Put local changes in
# /etc/apparmor.d/local/${package_name}-bwrap instead.
abi <abi/4.0>,
include <tunables/global>

profile ${package_name}-bwrap /usr/bin/bwrap flags=(unconfined) {
    userns,

    include if exists <local/${package_name}-bwrap>
}
BWRAP_APPARMOR_EOF
    then
        if apparmor_parser -Q "\$BWRAP_PROFILE" >/dev/null 2>&1; then
            apparmor_parser -r "\$BWRAP_PROFILE" >/dev/null 2>&1 || echo "Note: bwrap AppArmor profile staged but not loaded now; it will apply on the next AppArmor reload or reboot."
            echo "Cowork bwrap AppArmor profile installed at \$BWRAP_PROFILE"
        else
            rm -f "\$BWRAP_PROFILE"
            echo "AppArmor on this system does not support the userns rule; skipping bwrap profile (not required here)."
        fi
    else
        # A failed write may leave a truncated profile behind; clear it.
        # The || true is mandatory: this branch is errexit-live, and a bare
        # rm fails the upgrade on a read-only /etc.
        rm -f "\$BWRAP_PROFILE" 2>/dev/null || true
        echo "Warning: could not write \$BWRAP_PROFILE; skipping bwrap AppArmor profile."
    fi
fi

exit 0
EOF
	chmod 755 "$out"
}

# Generate the postrm script.
#   $1 = output path
#   $2 = package name
#   $3 = apparmor.d directory (default /etc/apparmor.d)
#
# The AppArmor profiles are generated by postinst, not tracked by dpkg, so we
# unload and delete them ourselves. Cleanup lives in postrm (not prerm) so it
# also fires on purge and abort-install. Skip on upgrade — the incoming
# postinst rewrites and reloads them. 'disappear' is deliberately not handled:
# matching it would also clean during the overwrite-by-another-package flow.
# Two profiles: the Electron one (Chromium sandbox, #687) and the bwrap one
# (Cowork sandbox helper, #694).
# Per Debian Policy 10.7.3 the profiles are configuration: unload them
# whenever the confined binaries go away, but delete the files only on
# purge — a profile for an absent binary is a harmless no-op (google-chrome
# leaves its profile behind the same way).
write_deb_postrm() {
	local out="$1"
	local package_name="$2"
	local apparmor_dir="${3:-/etc/apparmor.d}"

	cat > "$out" << EOF
#!/bin/sh
set -e

case "\$1" in
    remove|purge|abort-install)
        for _profile in "$apparmor_dir/$package_name" \
            "$apparmor_dir/${package_name}-bwrap"; do
            if [ -e "\$_profile" ] \
                && command -v apparmor_parser >/dev/null 2>&1; then
                apparmor_parser -R "\$_profile" >/dev/null 2>&1 || true
            fi
            # Policy 10.7.3: config survives remove; delete on purge only.
            if [ "\$1" = purge ]; then
                rm -f "\$_profile" 2>/dev/null || true
            fi
        done
        ;;
esac

exit 0
EOF
	chmod 755 "$out"
}
