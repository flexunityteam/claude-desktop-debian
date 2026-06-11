#!/usr/bin/env bats
#
# mcp-cli.bats
# Tests for the MCP server CLI in scripts/mcp-cli.sh
#
# run_mcp_cli prefers the bundled Electron as Node runtime; the tests
# pass an empty electron path so it falls back to the system `node`
# (same JS code path — ELECTRON_RUN_AS_NODE makes Electron behave as
# plain node).
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	command -v node &>/dev/null || skip 'node not available'

	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	export XDG_CONFIG_HOME="$TEST_TMP/config"
	CONFIG="$XDG_CONFIG_HOME/Claude/claude_desktop_config.json"

	# shellcheck source=scripts/mcp-cli.sh
	source "$SCRIPT_DIR/../scripts/mcp-cli.sh"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# usage / argument handling
# =============================================================================

@test "mcp: no subcommand prints usage and exits 2" {
	run run_mcp_cli ''
	[[ $status -eq 2 ]]
	[[ $output == *'Usage: claude-desktop --mcp'* ]]
}

@test "mcp: --help prints usage and exits 0" {
	run run_mcp_cli '' --help
	[[ $status -eq 0 ]]
	[[ $output == *'Usage: claude-desktop --mcp'* ]]
}

@test "mcp: unknown subcommand exits 2" {
	run run_mcp_cli '' frobnicate
	[[ $status -eq 2 ]]
	[[ $output == *'unknown --mcp subcommand'* ]]
}

@test "mcp: add without command exits 2 with usage" {
	run run_mcp_cli '' add only-a-name
	[[ $status -eq 2 ]]
	[[ $output == *'Usage: claude-desktop --mcp add'* ]]
}

# =============================================================================
# list
# =============================================================================

@test "mcp list: no config file reports no servers" {
	run run_mcp_cli '' list
	[[ $status -eq 0 ]]
	[[ $output == *'No MCP servers configured.'* ]]
}

@test "mcp list: shows name, command, args and env keys" {
	mkdir -p "$(dirname "$CONFIG")"
	cat > "$CONFIG" <<'EOF'
{
  "mcpServers": {
    "fs": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
      "env": {"API_KEY": "secret"}
    }
  }
}
EOF
	run run_mcp_cli '' list
	[[ $status -eq 0 ]]
	[[ $output == *'fs: npx -y @modelcontextprotocol/server-filesystem /tmp'* ]]
	# Env *keys* are shown but never the values — they may be secrets.
	[[ $output == *'[env: API_KEY]'* ]]
	[[ $output != *'secret'* ]]
}

# =============================================================================
# add
# =============================================================================

@test "mcp add: creates config file with the server" {
	run run_mcp_cli '' add fs npx -y some-server /tmp
	[[ $status -eq 0 ]]
	[[ $output == *'Added MCP server "fs"'* ]]
	[[ -f $CONFIG ]]
	run node -e '
		const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
		const s = c.mcpServers.fs;
		if (s.command !== "npx") process.exit(1);
		if (JSON.stringify(s.args) !== JSON.stringify(["-y", "some-server", "/tmp"])) process.exit(1);
	' "$CONFIG"
	[[ $status -eq 0 ]]
}

@test "mcp add: preserves unrelated config keys" {
	mkdir -p "$(dirname "$CONFIG")"
	printf '{"preferences":{"keep":true},"coworkUserFilesPath":"/x"}' > "$CONFIG"
	run run_mcp_cli '' add fs mycmd
	[[ $status -eq 0 ]]
	run node -e '
		const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
		if (c.preferences.keep !== true) process.exit(1);
		if (c.coworkUserFilesPath !== "/x") process.exit(1);
		if (c.mcpServers.fs.command !== "mycmd") process.exit(1);
	' "$CONFIG"
	[[ $status -eq 0 ]]
}

@test "mcp add: duplicate name fails with exit 4 and keeps config unchanged" {
	run_mcp_cli '' add fs original >/dev/null
	local before
	before=$(cat "$CONFIG")
	run run_mcp_cli '' add fs other
	[[ $status -eq 4 ]]
	[[ $output == *'already exists'* ]]
	[[ $(cat "$CONFIG") == "$before" ]]
}

@test "mcp add: creates a .bak of the previous version" {
	run_mcp_cli '' add one cmd1 >/dev/null
	run_mcp_cli '' add two cmd2 >/dev/null
	[[ -f $CONFIG.bak ]]
	# The backup is the pre-modification state: has "one", not "two".
	run node -e '
		const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
		if (!c.mcpServers.one) process.exit(1);
		if (c.mcpServers.two) process.exit(1);
	' "$CONFIG.bak"
	[[ $status -eq 0 ]]
}

# =============================================================================
# remove
# =============================================================================

@test "mcp remove: deletes the server and keeps others" {
	run_mcp_cli '' add one cmd1 >/dev/null
	run_mcp_cli '' add two cmd2 >/dev/null
	run run_mcp_cli '' remove one
	[[ $status -eq 0 ]]
	[[ $output == *'Removed MCP server "one"'* ]]
	run run_mcp_cli '' list
	[[ $output != *'one:'* ]]
	[[ $output == *'two: cmd2'* ]]
}

@test "mcp remove: unknown name fails with exit 4 listing configured names" {
	run_mcp_cli '' add real cmd >/dev/null
	run run_mcp_cli '' remove ghost
	[[ $status -eq 4 ]]
	[[ $output == *'no MCP server named "ghost"'* ]]
	[[ $output == *'real'* ]]
}

# =============================================================================
# broken config safety
# =============================================================================

@test "mcp: refuses to touch unparsable config (exit 3, file untouched)" {
	mkdir -p "$(dirname "$CONFIG")"
	printf '{broken json' > "$CONFIG"
	run run_mcp_cli '' add fs cmd
	[[ $status -eq 3 ]]
	[[ $output == *'not valid JSON'* ]]
	[[ $output == *'Refusing to modify'* ]]
	[[ $(cat "$CONFIG") == '{broken json' ]]
	[[ ! -f $CONFIG.bak ]]
}

@test "mcp: refuses a config whose top level is not an object" {
	mkdir -p "$(dirname "$CONFIG")"
	printf '[1,2,3]' > "$CONFIG"
	run run_mcp_cli '' add fs cmd
	[[ $status -eq 3 ]]
	[[ $output == *'does not contain a JSON object'* ]]
	[[ $(cat "$CONFIG") == '[1,2,3]' ]]
}

# =============================================================================
# runtime selection
# =============================================================================

@test "mcp: falls back to system node when electron path is unusable" {
	# Empty path (all tests above) and a nonexistent path both fall
	# back; assert the nonexistent-path branch explicitly.
	run run_mcp_cli '/no/such/electron' list
	[[ $status -eq 0 ]]
	[[ $output == *'No MCP servers configured.'* ]]
}

@test "mcp: clear error when no runtime exists at all" {
	command() {
		if [[ $1 == '-v' && $2 == 'node' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	run run_mcp_cli '' list
	[[ $status -eq 1 ]]
	[[ $output == *'no JavaScript runtime found'* ]]
}
