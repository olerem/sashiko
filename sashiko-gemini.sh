#!/bin/bash
# Sashiko CLI Wrapper - Gemini Backend
# Uses Google Gemini API for AI code review

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- resource guard (see notes below) --------------------------------------
# /tmp on this box is tmpfs, i.e. RAM. Sashiko's `local` path has no
# --worktree-dir flag and falls through to tempfile's TempDir::new(), so it
# checks a full kernel tree (~1.8 GB) straight into RAM. Point TMPDIR at disk;
# this also covers the scratch-clone and prompt-bundle temp dirs.
export TMPDIR="${SASHIKO_TMPDIR:-$HOME/.cache/claude-scratch}"
mkdir -p "$TMPDIR"

# Re-exec under a memory-capped systemd scope so a runaway `git grep` is killed
# instead of throttling whatever invoked us (a Claude session shares its cgroup
# with its children and gets wedged in mem_cgroup_handle_over_high otherwise).
if [ -z "$SASHIKO_UNDER_CLIMIT" ] && command -v climit >/dev/null 2>&1; then
    export SASHIKO_UNDER_CLIMIT=1
    exec climit -m "${SASHIKO_MEM_LIMIT:-2G}" "$0" "$@"
fi
# ---------------------------------------------------------------------------

# Resolve the Gemini key from its 0600 file when it is not already in the
# environment, so the credential need not be exported from a shell rc at all.
# A file rather than gnome-keyring: this box is driven over SSH with no
# graphical login, so the login keyring is never unlocked and secret-tool
# cannot work here. Deliberately NOT exported - the chains below export only
# LLM_API_KEY, which is what sashiko reads, so the raw key never reaches
# unrelated child processes. No-op if the file is absent.
GEMINI_KEY_FILE="${GEMINI_KEY_FILE:-$HOME/.config/secrets/gemini}"
if [ -z "$GOOGLE_GENERATIVE_AI_API_KEY" ] && [ -r "$GEMINI_KEY_FILE" ]; then
    GOOGLE_GENERATIVE_AI_API_KEY="$(cat "$GEMINI_KEY_FILE")"
fi
SASHIKO_CLI="$SCRIPT_DIR/target/release/sashiko-cli"
DEFAULT_REPO="${SASHIKO_REPO:-/home/oleksij/tmp/linux.oper}"
LOG_DIR="$SCRIPT_DIR/reviews"

# Create log directory
mkdir -p "$LOG_DIR"

# Force Gemini API key
if [ -n "$GOOGLE_GENERATIVE_AI_API_KEY" ]; then
    export LLM_API_KEY="$GOOGLE_GENERATIVE_AI_API_KEY"
elif [ -z "$LLM_API_KEY" ]; then
    echo -e "${RED}✗${NC} No Gemini API key found!"
    echo "Please set GOOGLE_GENERATIVE_AI_API_KEY in your environment"
    exit 1
fi

# Check if sashiko-cli exists
if [ ! -f "$SASHIKO_CLI" ]; then
    echo -e "${RED}✗${NC} sashiko-cli not found at: $SASHIKO_CLI"
    echo "Please run: cargo build --release --no-default-features"
    exit 1
fi

# Ensure Settings.toml uses Gemini
check_config() {
    local config="$SCRIPT_DIR/Settings.toml"
    if ! grep -q '^provider = "gemini"' "$config"; then
        echo -e "${YELLOW}⚠${NC} Settings.toml is not configured for Gemini!"
        echo -e "${YELLOW}→${NC} Updating configuration..."
        sed -i 's/^provider = .*/provider = "gemini"/' "$config"
        sed -i 's/^model = .*/model = "gemini-3.1-pro-preview"/' "$config"
        sed -i 's/^max_input_tokens = .*/max_input_tokens = 900000/' "$config"
        echo -e "${GREEN}✓${NC} Configuration updated to use Gemini"
    fi
}

# Generate log filename based on commit hash
generate_log_filename() {
    local repo="$1"
    local revision="$2"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    
    # Get commit hash (handle ranges by taking the last commit)
    local hash=""
    if [[ "$revision" == *".."* ]]; then
        # Range specified, get last commit
        hash=$(cd "$repo" && git rev-parse "${revision#*..}" 2>/dev/null | cut -c1-8)
    else
        # Single commit
        hash=$(cd "$repo" && git rev-parse "$revision" 2>/dev/null | cut -c1-8)
    fi
    
    if [ -z "$hash" ]; then
        hash="unknown"
    fi
    
    echo "${LOG_DIR}/${hash}-gemini-${timestamp}.log"
}

# Show help
show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      ${BLUE}Sashiko Review - Google Gemini Backend${NC}        ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo
    echo "Usage: $0 [OPTIONS] [GIT_REVISION]"
    echo
    echo "Options:"
    echo "  -h, --help              Show this help"
    echo "  -r, --repo PATH         Path to git repository"
    echo "                          (default: $DEFAULT_REPO)"
    echo "  --no-ai                 Skip AI review (just test patch)"
    echo "  --prompt TEXT           Add custom prompt"
    echo "  --interactive           Interactive mode (pause on failure)"
    echo "  --no-log                Don't save output to log file"
    echo
    echo "Examples:"
    echo "  $0                      # Review HEAD in default repo"
    echo "  $0 HEAD~3..HEAD         # Review last 3 commits"
    echo "  $0 abc123               # Review specific commit"
    echo "  $0 -r /other/repo HEAD  # Review in different repo"
    echo
    echo "Output:"
    echo "  • Display on terminal (colored)"
    echo "  • Save to: $LOG_DIR/<hash>-gemini-<timestamp>.log"
    echo
    echo "Backend Details:"
    echo "  Provider: Google Gemini"
    echo "  Model: gemini-3.1-pro-preview"
    echo "  Context Window: 900K tokens"
    echo "  Cost: ~\$0.50-\$5 per review (varies by patch size)"
    echo
    echo "API Key: ${GREEN}✓${NC} GOOGLE_GENERATIVE_AI_API_KEY"
}

# Parse arguments
REPO_PATH="$DEFAULT_REPO"
REVISION="HEAD"
EXTRA_ARGS=()
CUSTOM_REPO=false
NO_LOG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -r|--repo)
            REPO_PATH="$2"
            CUSTOM_REPO=true
            shift 2
            ;;
        --no-log)
            NO_LOG=true
            shift
            ;;
        --no-ai|--interactive)
            EXTRA_ARGS+=("$1")
            shift
            ;;
        --prompt|--custom-prompt)
            EXTRA_ARGS+=("$1" "$2")
            shift 2
            ;;
        *)
            REVISION="$1"
            shift
            ;;
    esac
done

# Main execution
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}      ${BLUE}Sashiko Code Review - Google Gemini${NC}           ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo

# Check configuration
check_config

# Verify API key
echo -e "${GREEN}✓${NC} Using Google Gemini API (${LLM_API_KEY:0:20}...)"
echo -e "${BLUE}ℹ${NC} Model: gemini-3.1-pro-preview (900K context)"

# Verify repository
if [ ! -d "$REPO_PATH/.git" ] && [ ! -f "$REPO_PATH/.git" ]; then
    echo -e "${RED}✗${NC} Git repository not found: $REPO_PATH"
    exit 1
fi

# Generate log filename
if [ "$NO_LOG" = false ]; then
    LOG_FILE=$(generate_log_filename "$REPO_PATH" "$REVISION")
    echo -e "${BLUE}ℹ${NC} Output will be saved to: ${LOG_FILE##*/}"
fi

# Build command
CMD=("$SASHIKO_CLI" "local" "--repo" "$REPO_PATH")
CMD+=("${EXTRA_ARGS[@]}")
CMD+=("$REVISION")

echo
echo -e "${YELLOW}Repository:${NC} $REPO_PATH"
echo -e "${YELLOW}Reviewing:${NC} $REVISION"
echo

# Run the review
echo -e "${GREEN}━━━ Starting AI Review with Gemini ━━━${NC}"
echo

# Run with tee to show on screen and save to file
if [ "$NO_LOG" = false ]; then
    # Save header to log file
    {
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║      Sashiko Code Review - Google Gemini             ║"
        echo "╚══════════════════════════════════════════════════════╝"
        echo ""
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Repository: $REPO_PATH"
        echo "Revision: $REVISION"
        echo "Backend: Gemini (gemini-3.1-pro-preview)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
    } > "$LOG_FILE"
    
    # Run command and tee to file (strip color codes from log file)
    "${CMD[@]}" 2>&1 | tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")
    exit_code=${PIPESTATUS[0]}
else
    "${CMD[@]}"
    exit_code=$?
fi

echo
if [ $exit_code -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✓ Review completed successfully  ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════╝${NC}"
    
    if [ "$NO_LOG" = false ]; then
        echo -e "${CYAN}📄 Review saved to:${NC} $LOG_FILE"
        echo -e "${CYAN}📊 Log size:${NC} $(du -h "$LOG_FILE" | cut -f1)"
    fi
else
    echo -e "${RED}╔════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ✗ Review failed (exit: $exit_code)       ║${NC}"
    echo -e "${RED}╚════════════════════════════════════╝${NC}"
    
    if [ "$NO_LOG" = false ]; then
        echo -e "${YELLOW}⚠ Partial output saved to:${NC} $LOG_FILE"
    fi
fi

exit $exit_code
