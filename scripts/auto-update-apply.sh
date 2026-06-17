#!/bin/bash
#===============================================================================
# Claude Desktop — privileged update applier
#
# Installed to /usr/local/sbin/claude-desktop-apply-update (root-owned,
# mode 0755) by `claude-desktop --setup-auto-update`. A NOPASSWD sudoers
# drop-in lets the unprivileged auto-updater invoke ONLY this script, so
# the silent (Cursor-style) install never prompts for a password.
#
# This is the entire root surface of the auto-updater. It deliberately
# does one thing: validate that the argument is a claude-desktop .deb,
# then dpkg -i it. It must stay tiny and root-owned (not user-writable)
# so the sudoers grant can't be turned into arbitrary root execution by
# editing the script.
#
# Residual risk (inherent to any unattended root install): a process
# running as the invoking user could hand us a maliciously-built
# claude-desktop .deb. The package-name check below is a guard, not a
# trust boundary — anyone wanting real supply-chain assurance should
# install from a signed APT repo instead of building locally.
#===============================================================================
set -euo pipefail

deb="${1:-}"

if [[ -z $deb ]]; then
	echo "Usage: claude-desktop-apply-update <path-to.deb>" >&2
	exit 2
fi

if [[ ! -f $deb ]]; then
	echo "Error: '$deb' is not a file" >&2
	exit 2
fi

# The file must be a real Debian archive whose Package is claude-desktop.
pkg_name=$(dpkg-deb -f "$deb" Package 2>/dev/null || true)
if [[ $pkg_name != 'claude-desktop' ]]; then
	echo "Error: '$deb' is not a claude-desktop package (Package='$pkg_name')" >&2
	exit 3
fi

echo "Installing $deb ..."
dpkg -i "$deb"
echo "claude-desktop install complete."
