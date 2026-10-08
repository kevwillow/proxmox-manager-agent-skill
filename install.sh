#!/bin/bash
# install.sh — Install the proxmox-manager-agent skill into one or more
# agent skill directories.
#
# Usage:
#   ./install.sh                          # install for current user, all agents
#   ./install.sh --agent hermes           # install for Hermes only
#   ./install.sh --agent hermes,claude    # install for multiple agents
#   ./install.sh --agent all              # explicit "all"
#   ./install.sh --agent claude --prefix /opt   # install to /opt/<user>/.claude/skills/...
#   ./install.sh --openclaw-workspace /path/to/openclaw/workspace  # override OpenClaw path
#   ./install.sh --uninstall              # remove from all agents
#   ./install.sh --uninstall --agent hermes  # remove from one agent
#   ./install.sh --list                   # show what would be installed where
#
# Agents and their skill paths (user-level):
#   hermes    -> ~/.hermes/skills/proxmox-manager-agent/
#   claude    -> ~/.claude/skills/proxmox-manager-agent/
#   codex     -> ~/.codex/skills/proxmox-manager-agent/
#   opencode  -> ~/.config/opencode/skills/proxmox-manager-agent/
#   openclaw  -> $OPENCLAW_WORKSPACE/skills/proxmox-manager-agent/  (default ~/.openclaw/workspace)
#   cursor    -> ~/.cursor/skills/proxmox-manager-agent/
#
# What gets installed:
#   SKILL.md                              -> the skill itself
#   references/, scripts/, templates/     -> supporting files
#   README.md is NOT installed (skill loaders don't need it)

set -euo pipefail

# --- Defaults ---
AGENTS="hermes,claude,codex,opencode,openclaw,cursor"
ACTION="install"
PREFIX="$HOME"

# Try to auto-detect the actual OpenClaw workspace from its config.
# Falls back to the default path if not configured or the config isn't readable.
# Common config locations: top-level "workspace", "agent.workspace",
# "agents.defaults.workspace", "agents.<name>.workspace".
OPENCLAW_WORKSPACE=""
if [[ -f "$HOME/.openclaw/openclaw.json" ]]; then
    detected=$(python3 -c "
import json, sys
def find_ws(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == 'workspace' and isinstance(v, str) and v:
                return v
            r = find_ws(v)
            if r:
                return r
    if isinstance(obj, list):
        for item in obj:
            r = find_ws(item)
            if r:
                return r
    return None
try:
    with open('$HOME/.openclaw/openclaw.json') as f:
        cfg = json.load(f)
    ws = find_ws(cfg)
    if ws:
        print(ws)
except Exception:
    pass
" 2>/dev/null)
    if [[ -n "$detected" && -d "$detected" ]]; then
        OPENCLAW_WORKSPACE="$detected"
    fi
fi
OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)   AGENTS="$2"; shift 2 ;;
        --prefix)  PREFIX="$2"; shift 2 ;;
        --openclaw-workspace) OPENCLAW_WORKSPACE="$2"; shift 2 ;;
        --uninstall) ACTION="uninstall"; shift 1 ;;
        --list)    ACTION="list"; shift 1 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0 ;;
        *)
            echo "ERROR: unknown arg: $1" >&2
            exit 1 ;;
    esac
done

# Expand --agent all to the full list
if [[ "$AGENTS" == "all" ]]; then
    AGENTS="hermes,claude,codex,opencode,openclaw,cursor"
fi

# --- Resolve agent paths ---
agent_path() {
    local agent="$1"
    case "$agent" in
        hermes)   echo "$PREFIX/.hermes/skills/proxmox-manager-agent" ;;
        claude)   echo "$PREFIX/.claude/skills/proxmox-manager-agent" ;;
        codex)    echo "$PREFIX/.codex/skills/proxmox-manager-agent" ;;
        opencode) echo "$PREFIX/.config/opencode/skills/proxmox-manager-agent" ;;
        openclaw) echo "$OPENCLAW_WORKSPACE/skills/proxmox-manager-agent" ;;
        cursor)   echo "$PREFIX/.cursor/skills/proxmox-manager-agent" ;;
        *)
            echo "ERROR: unknown agent: $agent (valid: hermes, claude, codex, opencode, openclaw, cursor)" >&2
            return 1
            ;;
    esac
}

# --- Split agent list ---
IFS=',' read -ra AGENT_LIST <<< "$AGENTS"

# --- Resolve repo root (this script's directory) ---
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SKILL_SRC="$REPO_ROOT/SKILL.md"
REFS_SRC="$REPO_ROOT/references"
SCRIPTS_SRC="$REPO_ROOT/scripts"
TEMPLATES_SRC="$REPO_ROOT/templates"

# --- Validate source files exist ---
if [[ "$ACTION" != "list" && ! -f "$SKILL_SRC" ]]; then
    echo "ERROR: SKILL.md not found at $SKILL_SRC"
    echo "Run this script from inside the proxmox-manager-agent-skill repo."
    exit 1
fi

# --- do_install: install one agent ---
do_install() {
    local agent="$1"
    local target
    target="$(agent_path "$agent")" || return 1

    # For OpenClaw, the workspace is at $OPENCLAW_WORKSPACE/skills/
    # Make sure the workspace exists; create it if missing.
    if [[ "$agent" == "openclaw" && ! -d "$OPENCLAW_WORKSPACE" ]]; then
        echo "[$agent] Workspace not found at $OPENCLAW_WORKSPACE"
        echo "[$agent] Run 'openclaw onboard' first, or pass --openclaw-workspace to specify another path."
        return 1
    fi

    echo "[$agent] Installing to $target ..."
    mkdir -p "$target/references" "$target/scripts" "$target/templates"

    # SKILL.md is mandatory
    if [[ ! -f "$SKILL_SRC" ]]; then
        echo "[$agent] ERROR: $SKILL_SRC not found, skipping"
        return 1
    fi
    cp "$SKILL_SRC" "$target/SKILL.md"

    # references/, scripts/, templates/ — copy if they exist
    [[ -d "$REFS_SRC" ]]      && cp -r "$REFS_SRC/."      "$target/references/"
    [[ -d "$SCRIPTS_SRC" ]]   && cp -r "$SCRIPTS_SRC/."   "$target/scripts/"
    [[ -d "$TEMPLATES_SRC" ]] && cp -r "$TEMPLATES_SRC/." "$target/templates/"

    # Make scripts executable
    if [[ -d "$target/scripts" ]]; then
        chmod +x "$target/scripts"/*.sh 2>/dev/null || true
    fi
    if [[ -d "$target/templates" ]]; then
        chmod +x "$target/templates"/*.sh 2>/dev/null || true
    fi

    echo "[$agent] Installed:"
    echo "  $target/SKILL.md ($(wc -c < "$target/SKILL.md") bytes)"
    echo "  $target/references/ ($(ls "$target/references" 2>/dev/null | wc -l) files)"
    echo "  $target/scripts/   ($(ls "$target/scripts" 2>/dev/null | wc -l) files)"
    echo "  $target/templates/ ($(ls "$target/templates" 2>/dev/null | wc -l) files)"
}

# --- do_uninstall: remove one agent's installation ---
do_uninstall() {
    local agent="$1"
    local target
    target="$(agent_path "$agent")" || return 1

    if [[ -d "$target" ]]; then
        echo "[$agent] Removing $target ..."
        rm -rf "$target"
        echo "[$agent] Removed."
    else
        echo "[$agent] Not installed at $target, nothing to do."
    fi
}

# --- do_list: show what would be installed where ---
do_list() {
    echo "Source: $REPO_ROOT"
    echo
    echo "Targets:"
    for agent in "${AGENT_LIST[@]}"; do
        local target
        target="$(agent_path "$agent" 2>/dev/null)" || continue
        if [[ -d "$target" ]]; then
            echo "  [$agent] $target (INSTALLED)"
        else
            echo "  [$agent] $target (will install)"
        fi
    done
    if [[ " ${AGENT_LIST[*]} " == *" openclaw "* ]]; then
        echo "  OpenClaw workspace: $OPENCLAW_WORKSPACE"
    fi
    echo
    echo "Files to install:"
    echo "  SKILL.md ($(wc -c < "$SKILL_SRC" 2>/dev/null || echo 'MISSING') bytes)"
    echo "  references/  ($(ls "$REFS_SRC" 2>/dev/null | wc -l) files)"
    echo "  scripts/     ($(ls "$SCRIPTS_SRC" 2>/dev/null | wc -l) files)"
    echo "  templates/   ($(ls "$TEMPLATES_SRC" 2>/dev/null | wc -l) files)"
}

# --- Dispatch ---
case "$ACTION" in
    install)
        for agent in "${AGENT_LIST[@]}"; do
            do_install "$agent"
        done
        echo
        echo "Done. Next steps:"
        echo "  1. Restart your agent session so it picks up the new skill"
        echo "  2. Test by asking: 'what can you tell me about my Proxmox host?'"
        echo
        echo "If the agent asks for the Proxmox host's SSH details:"
        echo "  - User: zen-agent (or whichever you created)"
        echo "  - SSH key: ~/.ssh/<agent>-<host> on the agent's host"
        echo "  - See templates/zen-agent-sudoers for the sudoers file to install"
        ;;
    uninstall)
        for agent in "${AGENT_LIST[@]}"; do
            do_uninstall "$agent"
        done
        echo "Done."
        ;;
    list)
        do_list
        ;;
esac
