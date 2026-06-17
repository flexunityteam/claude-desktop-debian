# shellcheck shell=bash
# shellcheck disable=SC2154  # color vars assigned by _doctor_colors in doctor.sh
#===============================================================================
# Auto-Update
#
# Sourced by: scripts/launcher-common.sh (after doctor.sh — reuses the
# _doctor_colors output helpers and _info/_pass/_warn). Each packaging
# target installs auto-update.sh next to launcher-common.sh.
#
# Provides: run_auto_update — the `claude-desktop --update` entry point.
# Keeps the locally-built (fork) package current with upstream Claude
# Desktop releases, the same way Cursor self-updates:
#
#   claude-desktop --update --check   # report only, exit 10 if behind
#   claude-desktop --update --dry-run # show the plan, change nothing
#   claude-desktop --update           # build + install if behind
#   claude-desktop --update --force   # rebuild + reinstall regardless
#
# How "latest" is determined without tripping Cloudflare: Anthropic's
# download endpoint is Cloudflare-gated (plain curl gets 403, which is
# why resolve-download-url.py needs Playwright). Instead we read the
# upstream repo's git tags — CI tags every packaged release as
# `vREPO+claudeX.Y.Z`, so the newest `+claude` tag is the newest Claude
# version that has working download URLs + checksums committed.
#
# Build source = this fork. The upstream release tag is merged into a
# throwaway git worktree (not the user's checkout), so the build gets
# both upstream's new download URLs AND its updated patch scripts while
# keeping this fork's custom commits (cowork-setup, mcp-cli, …). A
# version bump that only changed URLs but shipped reworked patches would
# fail to build if we cherry-picked the URLs alone. If the merge
# conflicts, the update bails and asks for a manual `git merge` — the
# installed app is never touched on failure.
#
# Silent install needs root. run_auto_update shells out to the
# root-owned wrapper /usr/local/sbin/claude-desktop-apply-update via
# sudo (NOPASSWD drop-in installed by --setup-auto-update); the wrapper
# refuses anything that isn't a claude-desktop .deb.
#===============================================================================

# Local clone to build from, and the remote that carries upstream's
# version-pin commits/tags. Both env-overridable.
: "${CLAUDE_UPDATE_REPO:=$HOME/Developing/claude-desktop-debian}"
: "${CLAUDE_UPDATE_REMOTE:=origin}"

_au_cache_dir() {
	echo "${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-update"
}

_AU_APPLY_WRAPPER='/usr/local/sbin/claude-desktop-apply-update'
_AU_SUDOERS_FILE='/etc/sudoers.d/claude-desktop-update'
_AU_TIMER='claude-desktop-update.timer'

# Directory the packaging installs our sibling files into (unit
# templates, the apply-wrapper source). Resolved from this file's path.
_au_lib_dir() {
	cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# --- Probes (standalone so the BATS suite can shadow them) ---

# Installed package version, or empty if not installed via dpkg.
_au_installed_version() {
	dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null
}

# Newest upstream tag of the form vX+claudeY. Prefers gh (no rate
# limit when authed); falls back to the public GitHub API via curl.
_au_latest_tag() {
	local repo='aaddrick/claude-desktop-debian'
	local tags=''
	if command -v gh &>/dev/null; then
		tags=$(gh api "repos/$repo/tags" --jq '.[].name' 2>/dev/null)
	fi
	if [[ -z $tags ]] && command -v curl &>/dev/null; then
		tags=$(curl -fsSL "https://api.github.com/repos/$repo/tags" 2>/dev/null \
			| grep -oE '"name":[[:space:]]*"[^"]+"' \
			| sed -E 's/.*"name":[[:space:]]*"([^"]+)".*/\1/')
	fi
	# Newest +claude tag wins; the API returns tags newest-first.
	printf '%s\n' "$tags" | grep -m1 '+claude'
}

# Extract the Claude version (X.Y.Z) from a vREPO+claudeX.Y.Z tag.
_au_tag_claude_version() {
	printf '%s' "$1" | sed -nE 's/.*\+claude([0-9]+\.[0-9]+\.[0-9]+).*/\1/p'
}

# Desktop notification (best-effort) plus a stdout line.
_au_notify() {
	local urgency="$1" title="$2" body="$3"
	command -v notify-send &>/dev/null \
		&& notify-send -u "$urgency" "$title" "$body" 2>/dev/null || true
	echo "$title — $body"
}

# 0 if version $1 is strictly newer than $2 (dpkg semantics).
_au_version_newer() {
	dpkg --compare-versions "$1" gt "$2"
}

# --- Update execution ---

# Merge the upstream tag into a throwaway worktree, build the .deb
# there, and silently install it. A merge (not a pin-file cherry-pick)
# is required because a new Claude version usually ships with updated
# patch scripts — pulling only the download URLs would build the new
# version against stale patches and fail. The merge brings upstream's
# patch fixes + URLs while keeping this fork's commits; on conflict we
# bail safely and ask for a manual merge. The worktree keeps the user's
# real checkout completely untouched. Returns non-zero on failure.
_au_perform_update() {
	local tag="$1" target="$2"
	local repo="$CLAUDE_UPDATE_REPO"

	if [[ ! -d $repo/.git ]]; then
		_au_notify critical 'Claude auto-update failed' \
			"No git clone at $repo (set CLAUDE_UPDATE_REPO)"
		return 1
	fi
	if [[ ! -x $_AU_APPLY_WRAPPER ]]; then
		_au_notify critical 'Claude auto-update failed' \
			'Install step missing — run: claude-desktop --setup-auto-update'
		return 1
	fi

	echo "Updating Claude Desktop to $target (from $tag)..."

	git -C "$repo" fetch "$CLAUDE_UPDATE_REMOTE" --tags --quiet || {
		_au_notify critical 'Claude auto-update failed' 'git fetch failed'
		return 1
	}

	# Isolated build tree at fork-HEAD; removed on every exit path.
	local wt
	wt="$(_au_cache_dir)/build-tree"
	git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
	rm -rf "$wt"
	# shellcheck disable=SC2064  # expand repo/wt now, on trap set
	trap "git -C '$repo' worktree remove --force '$wt' 2>/dev/null || true; rm -rf '$wt'" RETURN

	git -C "$repo" worktree add --quiet --detach "$wt" HEAD || {
		_au_notify critical 'Claude auto-update failed' \
			'Could not create build worktree'
		return 1
	}

	# Merge upstream's release into the fork's tree. Conflicts mean the
	# fork has diverged from upstream in a way only a human should
	# resolve — bail without touching the installed app. The merge
	# commit needs an identity (unattended runs have none); it lives
	# only in the throwaway worktree and is never pushed.
	if ! git -C "$wt" \
		-c user.name='claude-desktop auto-update' \
		-c user.email='auto-update@localhost' \
		merge --no-edit "$tag" >/dev/null 2>&1; then
		git -C "$wt" merge --abort 2>/dev/null || true
		_au_notify critical 'Claude auto-update needs a manual merge' \
			"Merging $tag into your fork conflicts. Resolve in $repo: git merge $tag"
		return 1
	fi

	( cd "$wt" && ./build.sh --build deb --clean yes ) || {
		_au_notify critical 'Claude auto-update failed' \
			"build.sh failed for $target (patches may need an upstream fix)"
		return 1
	}

	# build.sh writes claude-desktop_<ver>_amd64.deb into its cwd (the
	# worktree). Newest by mtime, in case an older artifact lingers.
	local built='' candidate
	for candidate in "$wt"/claude-desktop_*_*.deb; do
		[[ -f $candidate ]] || continue
		[[ -z $built || $candidate -nt $built ]] && built="$candidate"
	done
	if [[ -z $built ]]; then
		_au_notify critical 'Claude auto-update failed' 'No .deb produced'
		return 1
	fi

	# Stage at a fixed path the wrapper trusts, then install via sudo.
	local cache deb
	cache=$(_au_cache_dir)
	mkdir -p "$cache"
	deb="$cache/claude-desktop.deb"
	cp -f "$built" "$deb"

	if ! sudo -n "$_AU_APPLY_WRAPPER" "$deb"; then
		_au_notify critical 'Claude auto-update failed' \
			'Silent install failed (sudoers rule missing?)'
		return 1
	fi

	_au_notify normal 'Claude Desktop updated' \
		"Now on $target. Restart Claude to use the new version."
	return 0
}

run_auto_update() {
	local mode='run'
	case "${1:-}" in
		'') ;;
		--check) mode='check' ;;
		--dry-run) mode='dry-run' ;;
		--force) mode='force' ;;
		--help|help)
			cat <<'EOF'
Usage: claude-desktop --update [--check|--dry-run|--force]

Keep the locally-built package current with upstream Claude Desktop
releases (builds from this fork, preserving local customizations).

  (no flag)   Build + install if a newer Claude version exists
  --check     Report only; exit 10 if an update is available
  --dry-run   Show what would happen; change nothing
  --force     Rebuild + reinstall even if already current

One-time setup (timer + silent-install permission):
  claude-desktop --setup-auto-update
EOF
			return 0
			;;
		*)
			echo "Error: unknown option '${1}'. See --update --help" >&2
			return 2
			;;
	esac

	_doctor_colors

	local installed latest_tag target
	installed=$(_au_installed_version)
	latest_tag=$(_au_latest_tag)
	target=$(_au_tag_claude_version "$latest_tag")

	if [[ -z $latest_tag || -z $target ]]; then
		echo "Could not determine the latest upstream version (offline?)." >&2
		return 1
	fi

	echo "Installed: ${installed:-none}   Latest packaged: $target ($latest_tag)"

	local behind=false
	if [[ $mode == 'force' ]]; then
		behind=true
	elif [[ -z $installed ]]; then
		# Not dpkg-installed (AppImage/Nix/manual) — nothing to upgrade.
		echo 'Claude Desktop is not installed via dpkg; --update only' \
			'manages .deb installs.'
		return 0
	elif _au_version_newer "$target" "$installed"; then
		behind=true
	fi

	if [[ $behind != true ]]; then
		echo "Already up to date."
		return 0
	fi

	case "$mode" in
		check)
			_au_notify normal 'Claude Desktop update available' \
				"$target is available (you have $installed). Run: claude-desktop --update"
			return 10
			;;
		dry-run)
			echo "Would update $installed -> $target:"
			echo "  1. git fetch $CLAUDE_UPDATE_REMOTE --tags"
			echo "  2. merge $latest_tag into a throwaway worktree of $CLAUDE_UPDATE_REPO"
			echo "  3. build.sh --build deb (in that worktree)"
			echo "  4. sudo $_AU_APPLY_WRAPPER <built .deb>"
			echo "Run without --dry-run to apply (conflicts abort safely)."
			return 0
			;;
		*)
			_au_perform_update "$latest_tag" "$target"
			return $?
			;;
	esac
}

# One-time setup: install the daily user timer and the privileged
# install path (root-owned wrapper + NOPASSWD sudoers drop-in).
run_setup_auto_update() {
	case "${1:-}" in
		'') ;;
		--disable)
			_doctor_colors
			systemctl --user disable --now "$_AU_TIMER" 2>/dev/null || true
			rm -f "$HOME/.config/systemd/user/$_AU_TIMER" \
				"$HOME/.config/systemd/user/claude-desktop-update.service"
			systemctl --user daemon-reload 2>/dev/null || true
			echo 'Auto-update timer removed.'
			echo "To also drop the install permission: sudo rm $_AU_SUDOERS_FILE $_AU_APPLY_WRAPPER"
			return 0
			;;
		--help|help)
			cat <<'EOF'
Usage: claude-desktop --setup-auto-update [--disable]

Install a daily user timer that runs `claude-desktop --update`, plus the
root-owned apply-wrapper and a NOPASSWD sudoers drop-in so updates
install silently (Cursor-style). Asks for sudo once for the root parts.

  --disable   Remove the timer (prints how to drop the sudo permission)
EOF
			return 0
			;;
		*)
			echo "Error: unknown option '${1}'. See --setup-auto-update --help" >&2
			return 2
			;;
	esac

	_doctor_colors
	local lib_dir
	lib_dir=$(_au_lib_dir)

	if ((EUID == 0)); then
		echo 'Run this as your normal user, not root —' \
			'it installs a per-user systemd timer (sudo is requested only' \
			'for the install permission).' >&2
		return 1
	fi

	echo 'Setting up Claude Desktop auto-update'
	echo '-------------------------------------'

	# --- User timer (no privileges) ---
	local unit_dir="$HOME/.config/systemd/user"
	mkdir -p "$unit_dir"
	if [[ -f $lib_dir/claude-desktop-update.service \
		&& -f $lib_dir/claude-desktop-update.timer ]]; then
		cp "$lib_dir/claude-desktop-update.service" "$unit_dir/"
		cp "$lib_dir/claude-desktop-update.timer" "$unit_dir/"
	else
		_warn "Unit templates not found in $lib_dir; cannot install timer."
		return 1
	fi
	if command -v systemctl &>/dev/null; then
		systemctl --user daemon-reload
		systemctl --user enable --now "$_AU_TIMER"
		_pass "Daily timer enabled ($_AU_TIMER)"
	else
		_warn 'systemctl --user unavailable; timer files copied but not enabled.'
	fi

	# --- Privileged install path (one sudo prompt) ---
	# Install the root-owned wrapper and a sudoers rule scoped to it.
	# Built as a single sudo invocation so the user is prompted once.
	local wrapper_src="$lib_dir/auto-update-apply.sh"
	if [[ ! -f $wrapper_src ]]; then
		_warn "Apply-wrapper source missing at $wrapper_src."
		return 1
	fi
	echo 'Installing the silent-install permission (needs sudo once)...'
	if sudo bash -s -- "$wrapper_src" "$_AU_APPLY_WRAPPER" \
		"$_AU_SUDOERS_FILE" "$USER" <<'SUDO_EOF'
set -euo pipefail
wrapper_src="$1"; wrapper_dst="$2"; sudoers="$3"; user="$4"
install -Dm755 "$wrapper_src" "$wrapper_dst"
tmp=$(mktemp)
printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$wrapper_dst" > "$tmp"
# Validate before installing — a bad sudoers file can lock out sudo.
if visudo -cf "$tmp" >/dev/null; then
	install -Dm440 "$tmp" "$sudoers"
	rm -f "$tmp"
else
	rm -f "$tmp"
	echo 'sudoers validation failed; not installing' >&2
	exit 1
fi
SUDO_EOF
	then
		_pass "Silent install enabled (wrapper + $_AU_SUDOERS_FILE)"
	else
		_warn 'Could not install the silent-install permission.'
		_info 'The timer is active but updates will fail at the install' \
			'step until this is fixed. Re-run --setup-auto-update.'
		return 1
	fi

	echo
	echo -e "${_green}${_bold}Auto-update is active.${_reset}"
	echo 'Claude Desktop will be checked daily and updated silently.'
	echo 'Check now with: claude-desktop --update --check'
	return 0
}
