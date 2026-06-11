#!/usr/bin/env bats
#
# cowork-setup.bats
# Tests for the Cowork KVM setup command in scripts/cowork-setup.sh
#
# cowork-setup.sh reuses helpers from doctor.sh (_cowork_distro_id,
# _find_virtiofsd, output helpers), so both are sourced. The system
# probes (_cowork_setup_cpu_virt_ok, _cowork_setup_kvm_state, ...) are
# standalone functions precisely so these tests can shadow them and
# run deterministically on any machine.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# shellcheck source=scripts/doctor.sh
	source "$SCRIPT_DIR/../scripts/doctor.sh"
	# shellcheck source=scripts/cowork-setup.sh
	source "$SCRIPT_DIR/../scripts/cowork-setup.sh"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Shadow every system probe so run_cowork_setup sees a fully healthy
# KVM host. Individual tests then break one probe at a time.
_stub_all_healthy() {
	_cowork_setup_cpu_virt_ok() { return 0; }
	_cowork_setup_kvm_state() { echo 'ok'; }
	_cowork_setup_vsock_ok() { return 0; }
	_cowork_distro_id() { echo 'debian'; }
	# Fake tool binaries on PATH so `command -v` finds them even when
	# the host doesn't have them installed.
	mkdir -p "$TEST_TMP/bin"
	local tool
	for tool in qemu-system-x86_64 qemu-system-aarch64 socat virtiofsd; do
		printf '#!/bin/sh\nexit 0\n' > "$TEST_TMP/bin/$tool"
		chmod +x "$TEST_TMP/bin/$tool"
	done
	PATH="$TEST_TMP/bin:$PATH"
}

# Make `command -v <tool>` fail for the given tool(s) regardless of
# what the host has installed. Same shadow-`command` trick as
# doctor.bats — a PATH tweak alone can't hide a real system binary.
_HIDDEN_TOOLS=''
_hide_tool() {
	local tool
	for tool in "$@"; do
		_HIDDEN_TOOLS+=" $tool "
	done
	command() {
		if [[ $1 == '-v' && $_HIDDEN_TOOLS == *" $2 "* ]]; then
			return 1
		fi
		builtin command "$@"
	}
}

# =============================================================================
# argument handling
# =============================================================================

@test "cowork-setup: --help prints usage and exits 0" {
	run run_cowork_setup --help
	[[ $status -eq 0 ]]
	[[ $output == *'Usage: claude-desktop --cowork-setup'* ]]
}

@test "cowork-setup: unknown option exits 2" {
	run run_cowork_setup --frobnicate
	[[ $status -eq 2 ]]
	[[ $output == *'unknown option'* ]]
}

# =============================================================================
# helper mappings
# =============================================================================

@test "cowork-setup: pkg cmd maps debian to apt-get" {
	[[ $(_cowork_setup_pkg_cmd debian) == 'apt-get install -y' ]]
	[[ $(_cowork_setup_pkg_cmd ubuntu) == 'apt-get install -y' ]]
}

@test "cowork-setup: pkg cmd maps fedora to dnf" {
	[[ $(_cowork_setup_pkg_cmd fedora) == 'dnf install -y' ]]
}

@test "cowork-setup: pkg cmd maps arch to pacman" {
	[[ $(_cowork_setup_pkg_cmd arch) == 'pacman -S --noconfirm' ]]
}

@test "cowork-setup: pkg cmd is empty for unknown distro" {
	[[ -z $(_cowork_setup_pkg_cmd gentoo) ]]
}

@test "cowork-setup: qemu packages per distro" {
	[[ $(uname -m) == 'x86_64' ]] || skip 'x86_64-specific mapping'
	[[ $(_cowork_setup_qemu_pkgs debian) == 'qemu-system-x86 qemu-utils' ]]
	[[ $(_cowork_setup_qemu_pkgs fedora) == 'qemu-kvm qemu-img' ]]
	[[ $(_cowork_setup_qemu_pkgs arch) == 'qemu-full' ]]
}

# =============================================================================
# run_cowork_setup: healthy host
# =============================================================================

@test "cowork-setup: all healthy reports ready and exits 0" {
	_stub_all_healthy
	run run_cowork_setup
	[[ $status -eq 0 ]]
	[[ $output == *'Everything the KVM backend needs is in place'* ]]
	[[ $output != *'sudo '* ]]
}

# =============================================================================
# run_cowork_setup: dry-run plans (no --install => print, exit 1)
# =============================================================================

@test "cowork-setup: no CPU virtualization aborts without a plan" {
	_stub_all_healthy
	_cowork_setup_cpu_virt_ok() { return 1; }
	run run_cowork_setup
	[[ $status -eq 1 ]]
	[[ $output == *'CPU virtualization: not reported'* ]]
	[[ $output != *'--install'* ]]
}

@test "cowork-setup: inaccessible /dev/kvm plans usermod" {
	_stub_all_healthy
	_cowork_setup_kvm_state() { echo 'inaccessible'; }
	_cowork_setup_in_kvm_group() { return 1; }
	run run_cowork_setup
	[[ $status -eq 1 ]]
	[[ $output == *'sudo usermod -aG kvm'* ]]
	[[ $output == *'--cowork-setup --install'* ]]
}

@test "cowork-setup: inaccessible /dev/kvm with membership pending hints re-login" {
	_stub_all_healthy
	_cowork_setup_kvm_state() { echo 'inaccessible'; }
	_cowork_setup_in_kvm_group() { return 0; }
	run run_cowork_setup
	[[ $output == *'log out and back in'* ]]
	[[ $output != *'usermod'* ]]
}

@test "cowork-setup: missing /dev/kvm plans modprobe of kvm module" {
	_stub_all_healthy
	_cowork_setup_kvm_state() { echo 'missing'; }
	_cowork_setup_kvm_module() { echo 'kvm_intel'; }
	run run_cowork_setup
	[[ $status -eq 1 ]]
	[[ $output == *'sudo modprobe kvm_intel'* ]]
}

@test "cowork-setup: missing qemu plans distro package install" {
	[[ $(uname -m) == 'x86_64' ]] || skip 'x86_64-specific plan'
	_stub_all_healthy
	_hide_tool qemu-system-x86_64
	run run_cowork_setup
	[[ $status -eq 1 ]]
	[[ $output == *'QEMU: qemu-system-x86_64 not found'* ]]
	[[ $output == *'sudo apt-get install -y qemu-system-x86 qemu-utils'* ]]
}

@test "cowork-setup: missing socat plans socat install" {
	_stub_all_healthy
	_hide_tool socat
	run run_cowork_setup
	[[ $status -eq 1 ]]
	[[ $output == *'sudo apt-get install -y socat'* ]]
}

@test "cowork-setup: off-PATH virtiofsd plans a symlink, not a package" {
	_stub_all_healthy
	_hide_tool virtiofsd
	_find_virtiofsd() { echo '/usr/libexec/virtiofsd'; }
	run run_cowork_setup
	[[ $status -eq 1 ]]
	[[ $output == *'found at /usr/libexec/virtiofsd but not on PATH'* ]]
	[[ $output == *'sudo ln -sf /usr/libexec/virtiofsd /usr/local/bin/virtiofsd'* ]]
	[[ $output != *'install -y virtiofsd'* ]]
}

@test "cowork-setup: absent virtiofsd plans package install on debian" {
	_stub_all_healthy
	_hide_tool virtiofsd
	_find_virtiofsd() { echo ''; }
	run run_cowork_setup
	[[ $status -eq 1 ]]
	[[ $output == *'sudo apt-get install -y virtiofsd'* ]]
}

@test "cowork-setup: absent virtiofsd plans qemu-full on arch" {
	_stub_all_healthy
	_cowork_distro_id() { echo 'arch'; }
	_hide_tool virtiofsd
	_find_virtiofsd() { echo ''; }
	run run_cowork_setup
	[[ $status -eq 1 ]]
	[[ $output == *'sudo pacman -S --noconfirm qemu-full'* ]]
	[[ $output != *'pacman -S --noconfirm virtiofsd'* ]]
}

@test "cowork-setup: arch plans qemu-full only once for qemu+virtiofsd" {
	_stub_all_healthy
	_cowork_distro_id() { echo 'arch'; }
	_hide_tool qemu-system-x86_64 qemu-system-aarch64 virtiofsd
	_find_virtiofsd() { echo ''; }
	run run_cowork_setup
	[[ $status -eq 1 ]]
	local count
	count=$(grep -c 'pacman -S --noconfirm qemu-full' <<< "$output")
	[[ $count -eq 1 ]]
}

@test "cowork-setup: missing vsock plans modprobe + persistence" {
	_stub_all_healthy
	_cowork_setup_vsock_ok() { return 1; }
	run run_cowork_setup
	[[ $status -eq 1 ]]
	[[ $output == *'sudo modprobe vhost_vsock'* ]]
	[[ $output == *'/etc/modules-load.d/claude-cowork.conf'* ]]
}

@test "cowork-setup: dry run never executes the planned commands" {
	_stub_all_healthy
	_cowork_setup_vsock_ok() { return 1; }
	# A modprobe in PATH that would create a sentinel if executed.
	printf '#!/bin/sh\ntouch "%s/executed"\n' "$TEST_TMP" \
		> "$TEST_TMP/bin/modprobe"
	chmod +x "$TEST_TMP/bin/modprobe"
	run run_cowork_setup
	[[ $status -eq 1 ]]
	[[ ! -e "$TEST_TMP/executed" ]]
}

# =============================================================================
# run_cowork_setup --install
# =============================================================================

@test "cowork-setup: --install runs the plan via sudo" {
	_stub_all_healthy
	_cowork_setup_vsock_ok() { return 1; }
	# Fake sudo records its argv instead of escalating.
	printf '#!/bin/sh\necho "SUDO: $*" >> "%s/sudo.log"\nexit 0\n' "$TEST_TMP" \
		> "$TEST_TMP/bin/sudo"
	chmod +x "$TEST_TMP/bin/sudo"
	run run_cowork_setup --install
	[[ $status -eq 0 ]]
	[[ $output == *'Setup complete'* ]]
	grep -q 'SUDO: modprobe vhost_vsock' "$TEST_TMP/sudo.log"
	grep -q 'modules-load.d/claude-cowork.conf' "$TEST_TMP/sudo.log"
}

@test "cowork-setup: --install reports failed commands and exits 1" {
	_stub_all_healthy
	_cowork_setup_vsock_ok() { return 1; }
	printf '#!/bin/sh\nexit 1\n' > "$TEST_TMP/bin/sudo"
	chmod +x "$TEST_TMP/bin/sudo"
	run run_cowork_setup --install
	[[ $status -eq 1 ]]
	[[ $output == *'command(s) failed'* ]]
}

@test "cowork-setup: --install on healthy host changes nothing and exits 0" {
	_stub_all_healthy
	run run_cowork_setup --install
	[[ $status -eq 0 ]]
	[[ $output == *'Everything the KVM backend needs is in place'* ]]
}

@test "cowork-setup: --install mentions re-login after usermod" {
	_stub_all_healthy
	_cowork_setup_kvm_state() { echo 'inaccessible'; }
	_cowork_setup_in_kvm_group() { return 1; }
	printf '#!/bin/sh\nexit 0\n' > "$TEST_TMP/bin/sudo"
	chmod +x "$TEST_TMP/bin/sudo"
	run run_cowork_setup --install
	[[ $status -eq 0 ]]
	[[ $output == *'log out and back in'* ]]
}
