# shellcheck shell=bash
#===============================================================================
# MCP Server CLI
#
# Sourced by: scripts/launcher-common.sh (which is in turn sourced by the
# per-package launcher scripts — deb, rpm, AppImage, Nix). Each packaging
# target installs mcp-cli.sh next to launcher-common.sh.
#
# Provides: run_mcp_cli — the `claude-desktop --mcp <list|add|remove>`
# entry point. Edits the mcpServers section of claude_desktop_config.json
# without touching anything else in the file (the config also carries
# preferences, cowork paths, device pairings, ...).
#
# Safety contract:
#   - The file is parsed before any write; unparsable JSON aborts the
#     operation untouched (broken config is the most common user-reported
#     MCP failure — the CLI must never make it worse).
#   - Writes are atomic: serialize to a tmp file in the same directory,
#     then rename over the original.
#   - A one-deep backup (.bak) of the previous version is kept on every
#     successful modification.
#
# JSON is handled by the bundled Electron running as plain Node
# (ELECTRON_RUN_AS_NODE=1), so no system python3/node is required. A
# system `node` is used as fallback when the Electron path is missing
# (e.g. in tests).
#===============================================================================

# Node program implementing the actual config surgery. Reads the config
# path from CLAUDE_MCP_CONFIG; argv: <op> [args...].
# Exit codes: 0 ok, 2 usage, 3 unparsable config, 4 name conflict/missing.
# shellcheck disable=SC2016  # single quotes are deliberate: JS, not shell
_MCP_CLI_JS='
const fs = require("fs");
const path = require("path");

const configPath = process.env.CLAUDE_MCP_CONFIG;
const [op, ...args] = process.argv.slice(1);

function die(code, msg) {
	console.error(msg);
	process.exit(code);
}

let cfg = {};
let existed = false;
if (fs.existsSync(configPath)) {
	existed = true;
	const raw = fs.readFileSync(configPath, "utf8");
	try {
		cfg = JSON.parse(raw);
	} catch (err) {
		die(
			3,
			`Error: ${configPath} is not valid JSON (${err.message}).\n` +
				"Refusing to modify it. Fix the syntax error first " +
				"(tip: python3 -m json.tool on the file shows the position).",
		);
	}
	if (typeof cfg !== "object" || cfg === null || Array.isArray(cfg)) {
		die(3, `Error: ${configPath} does not contain a JSON object.`);
	}
}
if (typeof cfg.mcpServers !== "object" || cfg.mcpServers === null) {
	cfg.mcpServers = {};
}
const servers = cfg.mcpServers;

function writeConfig() {
	const dir = path.dirname(configPath);
	fs.mkdirSync(dir, { recursive: true });
	if (existed) {
		fs.copyFileSync(configPath, configPath + ".bak");
	}
	const tmp = path.join(dir, `.${path.basename(configPath)}.tmp${process.pid}`);
	fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2) + "\n");
	fs.renameSync(tmp, configPath);
}

switch (op) {
	case "list": {
		const names = Object.keys(servers);
		if (names.length === 0) {
			console.log("No MCP servers configured.");
			break;
		}
		for (const name of names.sort()) {
			const s = servers[name] ?? {};
			const cmd = [s.command, ...(Array.isArray(s.args) ? s.args : [])]
				.filter(Boolean)
				.join(" ");
			let line = `${name}: ${cmd || "(no command)"}`;
			const envKeys = Object.keys(s.env ?? {});
			if (envKeys.length > 0) {
				line += `  [env: ${envKeys.join(", ")}]`;
			}
			console.log(line);
		}
		break;
	}
	case "add": {
		const [name, command, ...rest] = args;
		if (!name || !command) {
			die(2, "Usage: claude-desktop --mcp add <name> <command> [args...]");
		}
		if (Object.prototype.hasOwnProperty.call(servers, name)) {
			die(
				4,
				`Error: an MCP server named "${name}" already exists.\n` +
					`Remove it first: claude-desktop --mcp remove ${name}`,
			);
		}
		servers[name] = { command, args: rest };
		writeConfig();
		console.log(`Added MCP server "${name}".`);
		console.log("Restart Claude Desktop for the change to take effect.");
		break;
	}
	case "remove": {
		const [name] = args;
		if (!name) {
			die(2, "Usage: claude-desktop --mcp remove <name>");
		}
		if (!Object.prototype.hasOwnProperty.call(servers, name)) {
			const names = Object.keys(servers);
			die(
				4,
				`Error: no MCP server named "${name}".` +
					(names.length > 0
						? ` Configured: ${names.sort().join(", ")}`
						: " No servers are configured."),
			);
		}
		delete servers[name];
		writeConfig();
		console.log(`Removed MCP server "${name}".`);
		console.log("Restart Claude Desktop for the change to take effect.");
		break;
	}
	default:
		die(2, `Error: unknown --mcp subcommand "${op ?? ""}".`);
}
'

_mcp_cli_usage() {
	cat <<'EOF'
Usage: claude-desktop --mcp <subcommand>

Manage MCP servers in claude_desktop_config.json.

Subcommands:
  list                          List configured MCP servers
  add <name> <command> [args]   Add a server (fails if the name exists)
  remove <name>                 Remove a server

The config is validated before every write; a .bak of the previous
version is kept next to it. Environment variables for a server can be
added by editing the file's "env" object by hand.
EOF
}

# Entry point. Arguments: $1 = electron path, $2... = subcommand + args
run_mcp_cli() {
	local electron_exec="${1:-}"
	shift || true

	if [[ $# -eq 0 || ${1:-} == '--help' || ${1:-} == 'help' ]]; then
		_mcp_cli_usage
		[[ $# -eq 0 ]] && return 2
		return 0
	fi

	local config_path="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
	config_path="$config_path/claude_desktop_config.json"

	# Prefer the bundled Electron as Node runtime (always shipped);
	# fall back to a system node when the Electron path is unusable.
	local -a runner
	if [[ -n $electron_exec && -x $electron_exec ]]; then
		runner=(env ELECTRON_RUN_AS_NODE=1 "$electron_exec")
	elif command -v node &>/dev/null; then
		runner=(node)
	else
		echo 'Error: no JavaScript runtime found (bundled Electron' \
			'missing and no system node).' >&2
		return 1
	fi

	CLAUDE_MCP_CONFIG="$config_path" "${runner[@]}" -e "$_MCP_CLI_JS" "$@"
}
