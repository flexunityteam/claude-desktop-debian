# shellcheck shell=bash
# shellcheck disable=SC2154  # color vars assigned by _doctor_colors in doctor.sh
#===============================================================================
# Cowork KVM Setup
#
# Sourced by: scripts/launcher-common.sh (after doctor.sh — this file
# reuses _cowork_distro_id, _cowork_pkg_hint, _find_virtiofsd, and the
# _pass/_warn/_info output helpers defined there). Each packaging
# target installs cowork-setup.sh next to launcher-common.sh.
#
# Provides: run_cowork_setup — the `claude-desktop --cowork-setup`
# entry point. Cowork's strongest isolation backend (KVM micro-VM)
# needs QEMU, socat, virtiofsd, the vhost_vsock module, and an
# accessible /dev/kvm. Doctor diagnoses what's missing; this command
# closes the gap:
#
#   claude-desktop --cowork-setup            # report + show the plan
#   claude-desktop --cowork-setup --install  # actually run the plan
#
# Without --install nothing is executed — the exact commands are
# printed for review. With --install each command runs via sudo (or
# directly when already root). Package names come from the same
# per-distro mapping doctor uses for its fix hints.
#===============================================================================

# Each check appends the commands needed to close its gap to
# _cowork_setup_plan (newline-separated). Empty plan == ready.
_cowork_setup_plan=''

_cowork_setup_add_plan() {
	_cowork_setup_plan+="$1"$'\n'
}

# Probe one dependency and report. Arguments:
#   $1 = label, $2 = ok (0/1), $3 = pass text, $4 = warn text,
#   $5 = command to add to the plan when missing ('' = nothing to add)
_cowork_setup_check() {
	local label="$1" ok="$2" pass_text="$3" warn_text="$4" plan_cmd="$5"
	if [[ $ok == 0 ]]; then
		_pass "$label: $pass_text"
	else
		_warn "$label: $warn_text"
		[[ -n $plan_cmd ]] && _cowork_setup_add_plan "$plan_cmd"
	fi
}

# Host QEMU system binary name for this CPU.
_cowork_setup_qemu_bin() {
	case "$(uname -m)" in
		x86_64) echo 'qemu-system-x86_64' ;;
		aarch64) echo 'qemu-system-aarch64' ;;
		*) echo "qemu-system-$(uname -m)" ;;
	esac
}

# QEMU package set per distro/arch (the doctor hint covers x86 only).
_cowork_setup_qemu_pkgs() {
	local distro="$1"
	local m
	m="$(uname -m)"
	case "$distro" in
		debian|ubuntu)
			if [[ $m == 'aarch64' ]]; then
				echo 'qemu-system-arm qemu-utils'
			else
				echo 'qemu-system-x86 qemu-utils'
			fi
			;;
		fedora) echo 'qemu-kvm qemu-img' ;;
		arch) echo 'qemu-full' ;;
		*) echo '' ;;
	esac
}

# Package-install command prefix per distro ('' = unknown manager).
_cowork_setup_pkg_cmd() {
	case "$1" in
		debian|ubuntu) echo 'apt-get install -y' ;;
		fedora) echo 'dnf install -y' ;;
		arch) echo 'pacman -S --noconfirm' ;;
		*) echo '' ;;
	esac
}

# --- System probes ---
# Kept as standalone functions so the BATS suite can shadow them and
# exercise run_cowork_setup deterministically on any machine.

# 0 = CPU reports VT-x/AMD-V.
_cowork_setup_cpu_virt_ok() {
	grep -qE 'vmx|svm' /proc/cpuinfo 2>/dev/null
}

# Prints: ok | inaccessible | missing
_cowork_setup_kvm_state() {
	if [[ -e /dev/kvm ]]; then
		if [[ -r /dev/kvm && -w /dev/kvm ]]; then
			echo 'ok'
		else
			echo 'inaccessible'
		fi
	else
		echo 'missing'
	fi
}

# 0 = vhost_vsock module loaded.
_cowork_setup_vsock_ok() {
	[[ -e /dev/vhost-vsock ]]
}

# 0 = the user is already a member of the kvm group (per group
# database — a pending re-login means the session doesn't show it yet).
_cowork_setup_in_kvm_group() {
	local user="${SUDO_USER:-$USER}"
	getent group kvm 2>/dev/null | grep -qE "[:,]$user(,|$)"
}

# Name of the KVM kernel module for this CPU.
_cowork_setup_kvm_module() {
	if grep -q svm /proc/cpuinfo 2>/dev/null; then
		echo 'kvm_amd'
	else
		echo 'kvm_intel'
	fi
}

run_cowork_setup() {
	local do_install=false
	case "${1:-}" in
		'') ;;
		--install) do_install=true ;;
		--help|help)
			cat <<'EOF'
Usage: claude-desktop --cowork-setup [--install]

Check (and optionally install) everything Cowork's KVM micro-VM
backend needs: QEMU, socat, virtiofsd, the vhost_vsock kernel module,
and an accessible /dev/kvm.

Without --install the needed commands are only printed for review.
With --install they are executed via sudo.
EOF
			return 0
			;;
		*)
			echo "Error: unknown option '${1}'. See --cowork-setup --help" >&2
			return 2
			;;
	esac

	_doctor_colors
	_cowork_setup_plan=''
	local distro pkg_cmd qemu_bin
	distro=$(_cowork_distro_id)
	pkg_cmd=$(_cowork_setup_pkg_cmd "$distro")
	qemu_bin=$(_cowork_setup_qemu_bin)

	echo
	echo 'Cowork KVM Setup'
	echo '----------------'

	# -- CPU virtualization support --
	# Without VT-x/AMD-V there is nothing to install: KVM cannot work
	# and Cowork stays on the bubblewrap backend.
	if _cowork_setup_cpu_virt_ok; then
		_pass 'CPU virtualization: supported (vmx/svm)'
	else
		_warn 'CPU virtualization: not reported by /proc/cpuinfo'
		_info '  Enable VT-x / AMD-V in BIOS/UEFI, or accept the'
		_info '  bubblewrap backend — nothing to install for KVM.'
		return 1
	fi

	# -- /dev/kvm --
	case "$(_cowork_setup_kvm_state)" in
		ok)
			_pass '/dev/kvm: accessible'
			;;
		inaccessible)
			_warn '/dev/kvm: exists but not accessible for this user'
			if _cowork_setup_in_kvm_group; then
				# Already granted — the session just hasn't picked
				# it up. Re-planning usermod would be a no-op.
				_info '  Already in the kvm group: log out and back in'
				_info '  for the membership to take effect.'
			else
				# kvm group membership is the canonical udev grant.
				# Takes effect on next login.
				_cowork_setup_add_plan "usermod -aG kvm ${SUDO_USER:-$USER}"
			fi
			;;
		missing)
			_warn '/dev/kvm: not found'
			_cowork_setup_add_plan "modprobe $(_cowork_setup_kvm_module)"
			;;
	esac

	# -- QEMU --
	local qemu_pkgs
	qemu_pkgs=$(_cowork_setup_qemu_pkgs "$distro")
	_cowork_setup_check 'QEMU' \
		"$(command -v "$qemu_bin" &>/dev/null; echo $?)" \
		"$qemu_bin found" \
		"$qemu_bin not found" \
		"${pkg_cmd:+$pkg_cmd $qemu_pkgs}"

	# -- socat --
	_cowork_setup_check 'socat' \
		"$(command -v socat &>/dev/null; echo $?)" \
		'found' \
		'not found' \
		"${pkg_cmd:+$pkg_cmd socat}"

	# -- virtiofsd --
	# May ship off-PATH (see _find_virtiofsd in doctor.sh). The KVM
	# backend resolves it through $PATH only, so off-PATH needs a
	# symlink rather than a package install.
	local vfsd_path
	vfsd_path=$(_find_virtiofsd)
	if command -v virtiofsd &>/dev/null; then
		_pass 'virtiofsd: found on PATH'
	elif [[ -n $vfsd_path ]]; then
		_warn "virtiofsd: found at $vfsd_path but not on PATH"
		_cowork_setup_add_plan \
			"ln -sf $vfsd_path /usr/local/bin/virtiofsd"
	else
		_warn 'virtiofsd: not found'
		if [[ -n $pkg_cmd ]]; then
			if [[ $distro == 'arch' ]]; then
				# Arch ships virtiofsd inside qemu-full — there is
				# no standalone package. (Duplicates with the QEMU
				# entry are removed when the plan is finalized.)
				_cowork_setup_add_plan "$pkg_cmd qemu-full"
			else
				_cowork_setup_add_plan "$pkg_cmd virtiofsd"
			fi
		fi
	fi

	# -- vhost_vsock --
	if _cowork_setup_vsock_ok; then
		_pass 'vsock: module loaded'
	else
		_warn 'vsock: /dev/vhost-vsock not found'
		_cowork_setup_add_plan 'modprobe vhost_vsock'
		# Persist across reboots — modprobe alone lasts one boot.
		_cowork_setup_add_plan \
			"sh -c 'echo vhost_vsock > /etc/modules-load.d/claude-cowork.conf'"
	fi

	# -- Plan / execution --
	# Drop duplicate commands (e.g. qemu-full planned by both the QEMU
	# and the virtiofsd check on Arch) while preserving order.
	_cowork_setup_plan=$(printf '%s' "$_cowork_setup_plan" | awk '!seen[$0]++')
	echo
	if [[ -z $_cowork_setup_plan ]]; then
		echo -e "${_green}${_bold}Everything the KVM backend needs is in place.${_reset}"
		echo "Verify with: claude-desktop --doctor (Cowork Mode section)"
		return 0
	fi

	if [[ $do_install != true ]]; then
		echo 'The following commands would close the gaps above:'
		echo
		while IFS= read -r cmd; do
			[[ -n $cmd ]] && echo "  sudo $cmd"
		done <<< "$_cowork_setup_plan"
		echo
		echo 'Run them automatically with:'
		echo '  claude-desktop --cowork-setup --install'
		return 1
	fi

	# --install: execute the plan. Prefix sudo unless already root.
	local sudo_prefix=''
	if ((EUID != 0)); then
		if ! command -v sudo &>/dev/null; then
			echo 'Error: --install needs root privileges and sudo is not available.' >&2
			return 1
		fi
		sudo_prefix='sudo'
	fi

	local failures=0
	while IFS= read -r cmd; do
		[[ -z $cmd ]] && continue
		echo "Running: ${sudo_prefix:+$sudo_prefix }$cmd"
		# shellcheck disable=SC2086  # word-split the planned command
		if ! $sudo_prefix $cmd; then
			echo "  -> failed" >&2
			failures=$((failures + 1))
		fi
	done <<< "$_cowork_setup_plan"

	echo
	if ((failures > 0)); then
		echo -e "${_red}${_bold}$failures command(s) failed.${_reset} See output above."
		return 1
	fi
	echo -e "${_green}${_bold}Setup complete.${_reset}"
	if [[ $_cowork_setup_plan == *'usermod -aG kvm'* ]]; then
		echo 'Note: the kvm group membership takes effect after you log out and back in.'
	fi
	echo "Verify with: claude-desktop --doctor (Cowork Mode section)"
	return 0
}
