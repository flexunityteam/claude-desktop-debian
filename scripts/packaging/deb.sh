#!/usr/bin/env bash

# Arguments passed from the main script
version="$1"
architecture="$2"
work_dir="$3"           # The top-level build directory (e.g., ./build)
app_staging_dir="$4"    # Directory containing the prepared app files
package_name="$5"
maintainer="$6"
description="$7"

echo '--- Starting Debian Package Build ---'
echo "Version: $version"
echo "Architecture: $architecture"
echo "Work Directory: $work_dir"
echo "App Staging Directory: $app_staging_dir"
echo "Package Name: $package_name"

package_root="$work_dir/package"
install_dir="$package_root/usr"

# Clean previous package structure if it exists
rm -rf "$package_root"

# Create Debian package structure
echo "Creating package structure in $package_root..."
mkdir -p "$package_root/DEBIAN" || exit 1
mkdir -p "$install_dir/lib/$package_name" || exit 1
mkdir -p "$install_dir/share/applications" || exit 1
mkdir -p "$install_dir/share/icons" || exit 1
mkdir -p "$install_dir/bin" || exit 1

# --- Icon Installation ---
echo 'Installing icons...'
# Map: size -> filename suffix
declare -A icon_files=(
	[16]=13 [24]=11 [32]=10 [48]=8 [64]=7 [256]=6
)

for size in "${!icon_files[@]}"; do
	icon_dir="$install_dir/share/icons/hicolor/${size}x${size}/apps"
	mkdir -p "$icon_dir" || exit 1
	icon_source_path="$work_dir/claude_${icon_files[$size]}_${size}x${size}x32.png"
	if [[ -f $icon_source_path ]]; then
		echo "Installing ${size}x${size} icon..."
		install -Dm 644 "$icon_source_path" "$icon_dir/claude-desktop.png" || exit 1
	else
		echo "Warning: Missing ${size}x${size} icon at $icon_source_path"
	fi
done
echo 'Icons installed'

# --- Copy Application Files ---
echo "Copying application files from $app_staging_dir..."

# Copy local electron first if it was packaged (check if node_modules exists in staging)
if [[ -d $app_staging_dir/node_modules ]]; then
	echo 'Copying packaged electron...'
	cp -r "$app_staging_dir/node_modules" "$install_dir/lib/$package_name/" || exit 1
fi

# Install app.asar in Electron's resources directory where process.resourcesPath points
resources_dir="$install_dir/lib/$package_name/node_modules/electron/dist/resources"
mkdir -p "$resources_dir" || exit 1
cp "$app_staging_dir/app.asar" "$resources_dir/" || exit 1
cp -r "$app_staging_dir/app.asar.unpacked" "$resources_dir/" || exit 1
echo 'Application files copied to Electron resources directory'

# Copy shared launcher library (launcher-common.sh sources doctor.sh
# at runtime, so both must live in the same directory)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$(dirname "$script_dir")/launcher-common.sh" "$install_dir/lib/$package_name/" || exit 1
sed -i "s/@@WM_CLASS@@/$WM_CLASS/" "$install_dir/lib/$package_name/launcher-common.sh"
cp "$(dirname "$script_dir")/doctor.sh" "$install_dir/lib/$package_name/" || exit 1
cp "$(dirname "$script_dir")/mcp-cli.sh" "$install_dir/lib/$package_name/" || exit 1
cp "$(dirname "$script_dir")/cowork-setup.sh" "$install_dir/lib/$package_name/" || exit 1
echo 'Shared launcher library + doctor + mcp-cli + cowork-setup copied'

# --- Create Desktop Entry ---
echo 'Creating desktop entry...'
cat > "$install_dir/share/applications/claude-desktop.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=/usr/bin/claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=$WM_CLASS
EOF
echo 'Desktop entry created'

# --- Install AppStream metainfo (App Center / GNOME Software / KDE Discover) ---
echo 'Installing AppStream metainfo...'
metainfo_name='io.github.aaddrick.claude-desktop-debian.metainfo.xml'
install -Dm 644 "$script_dir/$metainfo_name" \
	"$install_dir/share/metainfo/$metainfo_name" || exit 1
echo 'AppStream metainfo installed'

# --- Create Launcher Script ---
echo 'Creating launcher script...'
cat > "$install_dir/bin/claude-desktop" << EOF
#!/usr/bin/env bash

# Source shared launcher library
source "/usr/lib/$package_name/launcher-common.sh"

# Handle --doctor flag before anything else
# (--fix as the second argument enables auto-remediation)
if [[ "\${1:-}" == '--doctor' ]]; then
	local_electron_path="/usr/lib/$package_name/node_modules/electron/dist/electron"
	run_doctor "\$local_electron_path" "\${2:-}"
	exit \$?
fi

# Handle --mcp subcommands (list/add/remove MCP servers in config)
if [[ "\${1:-}" == '--mcp' ]]; then
	shift
	local_electron_path="/usr/lib/$package_name/node_modules/electron/dist/electron"
	run_mcp_cli "\$local_electron_path" "\$@"
	exit \$?
fi

# Handle --cowork-setup (check/install KVM backend dependencies)
if [[ "\${1:-}" == '--cowork-setup' ]]; then
	run_cowork_setup "\${2:-}"
	exit \$?
fi

# Setup logging and environment
setup_logging || exit 1
setup_electron_env

# App path
app_path="/usr/lib/$package_name/node_modules/electron/dist/resources/app.asar"

cleanup_orphaned_cowork_daemon
cleanup_stale_desktop_helpers
cleanup_stale_lock
cleanup_stale_cowork_socket

# Log startup info
log_message '--- Claude Desktop Launcher Start ---'
log_message "Timestamp: \$(date)"
log_message "Arguments: \$@"
log_session_env

# Check for display
if ! check_display; then
	log_message 'No display detected (TTY session)'
	echo 'Error: Claude Desktop requires a graphical desktop environment.' >&2
	echo 'Please run from within an X11 or Wayland session, not from a TTY.' >&2
	exit 1
fi

# Detect display backend
detect_display_backend
if [[ \$is_wayland == true ]]; then
	log_message 'Wayland detected'
fi

# Determine Electron executable path
electron_exec='electron'
using_global_electron=false
local_electron_path="/usr/lib/$package_name/node_modules/electron/dist/electron"
if [[ -f \$local_electron_path ]]; then
	electron_exec="\$local_electron_path"
	log_message "Using local Electron: \$electron_exec"
else
	if command -v electron &> /dev/null; then
		using_global_electron=true
		log_message "Using global Electron: \$electron_exec"
	else
		log_message 'Error: Electron executable not found'
		if command -v zenity &> /dev/null; then
			zenity --error \
				--text='Claude Desktop cannot start because the Electron framework is missing.'
		elif command -v kdialog &> /dev/null; then
			kdialog --error \
				'Claude Desktop cannot start because the Electron framework is missing.'
		fi
		exit 1
	fi
fi

# Build electron args
build_electron_args 'deb'

# Bundled Electron: app.asar sits in its default resources/ dir next
# to the binary, so Electron auto-loads it. Passing the path again
# makes Electron treat it as a file-to-open, which the app forwards
# to its file-drop handler, producing a spurious "Attach app.asar?"
# prompt on launch and on every taskbar reopen (the second-instance
# argv path). Omitting it is the root-cause fix. See issue #696.
# Global (PATH) Electron has no co-located app.asar and would boot
# its default_app welcome screen instead — only there the explicit
# app path is load-bearing and must stay.
if [[ \$using_global_electron == true ]]; then
	electron_args+=("\$app_path")
	log_message "App (explicit arg, global Electron): \$app_path"
else
	log_message "App (auto-loaded by Electron): \$app_path"
fi

# Change to application directory
app_dir="/usr/lib/$package_name"
log_message "Changing directory to \$app_dir"
cd "\$app_dir" || { log_message "Failed to cd to \$app_dir"; exit 1; }

# Execute Electron and keep the launcher alive so explicit quit can
# clean up Desktop-owned helpers that outlive the Electron main process.
log_message "Executing: \$electron_exec \${electron_args[*]} \$*"
run_electron_and_cleanup "\$electron_exec" "\${electron_args[@]}" "\$@"
exit \$?
EOF
chmod +x "$install_dir/bin/claude-desktop" || exit 1
echo 'Launcher script created'

# --- Create Control File ---
echo 'Creating control file...'
# Electron is bundled with its own Node.js runtime, so nodejs/npm are not
# runtime dependencies. p7zip is only used at build time to extract the
# installer. bubblewrap is Recommended (not required): it provides the
# default namespace-sandbox isolation for Cowork mode; the app runs without
# it (Cowork falls back to host-direct). apt installs Recommends by default.
#
# Depends: the bundled Electron still links the canonical Chromium/GTK
# system set at runtime (ldd shows libgtk-3, libnss3, libatspi, libasound
# as direct links; libnotify/libsecret/libXss/libXtst load dynamically).
# This is the same dependency set electron-installer-debian declares for
# every Electron app. Desktop installs already have them; the declarations
# matter for minimal containers/VMs where a bare `apt install
# ./claude-desktop.deb` previously launched into missing-.so errors
# (case-doc S03). Ubuntu 24.04's t64 renames are covered: the t64
# packages carry Provides: for the old names.

cat > "$package_root/DEBIAN/control" << EOF
Package: $package_name
Version: $version
Section: utils
Priority: optional
Architecture: $architecture
Depends: libgtk-3-0, libnotify4, libnss3, libxss1, libxtst6, xdg-utils, libatspi2.0-0, libuuid1, libsecret-1-0, libasound2
Recommends: bubblewrap
Maintainer: $maintainer
Description: $description
 Claude is an AI assistant from Anthropic.
 This package provides the desktop interface for Claude.
 .
 Supported on Debian-based Linux distributions (Debian, Ubuntu, Linux Mint, MX Linux, etc.)
EOF
echo 'Control file created'

# --- Create Maintainer Scriptlets ---
# Generators live in deb-scriptlets.sh so the postinst/postrm logic
# (AppArmor profiles, marker preservation, purge-vs-remove) is
# unit-testable — see tests/deb-scriptlets.bats.
# shellcheck source=scripts/packaging/deb-scriptlets.sh
source "$script_dir/deb-scriptlets.sh"

echo 'Creating postinst script...'
write_deb_postinst "$package_root/DEBIAN/postinst" "$package_name" || exit 1
echo 'Postinst script created'

echo 'Creating postrm script...'
write_deb_postrm "$package_root/DEBIAN/postrm" "$package_name" || exit 1
echo 'Postrm script created'

# --- Build .deb Package ---
echo 'Building .deb package...'
deb_file="$work_dir/${package_name}_${version}_${architecture}.deb"

# Fix DEBIAN directory permissions (must be 755 for dpkg-deb)
echo 'Setting DEBIAN directory permissions...'
chmod 755 "$package_root/DEBIAN" || exit 1

# Fix script permissions in DEBIAN directory
echo 'Setting script permissions...'
chmod 755 "$package_root/DEBIAN/postinst" || exit 1
chmod 755 "$package_root/DEBIAN/postrm" || exit 1

# Normalize the installed tree before building. A restrictive build umask
# can leave directories at 0700, and dpkg-deb records file ownership
# verbatim unless told otherwise. Both bite at runtime: the launcher runs
# as the desktop user, who then can't traverse into app.asar.unpacked/ —
# silently breaking Cowork's daemon auto-launch (the fork is guarded by
# fs.existsSync(), which returns false on a directory it can't read, so
# the symptom is an endless connect ENOENT on the VM-service socket with
# no daemon log and no [cowork-autolaunch] line). Canonical modes: dirs
# and already-executable files 755, every other file 644. The blanket
# pass clears chrome-sandbox's setuid bit, but postinst re-asserts 4755
# after install, so the net result is unchanged.
echo 'Normalizing installed tree permissions...'
find "$install_dir" -type d -exec chmod 755 {} + || exit 1
find "$install_dir" -type f -exec chmod u=rwX,go=rX {} + || exit 1

# --root-owner-group forces root:root in the archive so a leaked build
# uid can't deny access on the installed system (the build does not run
# under fakeroot).
if ! dpkg-deb --root-owner-group --build "$package_root" "$deb_file"; then
	echo 'Failed to build .deb package' >&2
	exit 1
fi

echo "Deb package built successfully: $deb_file"
echo '--- Debian Package Build Finished ---'

exit 0
