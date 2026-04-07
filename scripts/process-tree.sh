#!/bin/sh
# ─────────────────────────────────────────────────────────────
# process-tree.sh
# Regenerates the Rojo project tree and sourcemap.
# Run this whenever you add/remove/rename source files.
#
# Does NOT install Wally packages or regenerate types.
# wally-package-types mutates Packages/ in place — running it
# a second time on already-mutated files causes errors. Types
# must only run right after a fresh wally install.
# Use install-packages.sh or setup.sh for that.
#
# Usage:
#   sh scripts/process-tree.sh [OPTIONS]
#
# Options:
#   --skip-tree     Skip generateRojoTree.js (reuse existing default.project.json)
#   --skip-map      Skip sourcemap generation
#   --watch         Watch relevant files and rerun on changes
#   --debounce-ms   Debounce delay for watch mode (default: 250)
#   --help, -h      Show this help message
# ─────────────────────────────────────────────────────────────

set -e
set -u

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'
BOLD='\033[1m'

if [ ! -t 1 ] || [ "${NO_COLOR:-}" = "1" ]; then
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' RESET='' BOLD=''
fi

# ── Helpers ───────────────────────────────────────────────────
print_step()    { printf "${BLUE}${BOLD}▶${RESET} ${BOLD}%s${RESET}\n" "$1"; }
print_success() { printf "${GREEN}✓${RESET} %s\n" "$1"; }
print_error()   { printf "${RED}✗ Error:${RESET} %s\n" "$1" >&2; }
print_warning() { printf "${YELLOW}⚠ Warning:${RESET} %s\n" "$1"; }
print_info()    { printf "${CYAN}ℹ${RESET} %s\n" "$1"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ── Help ──────────────────────────────────────────────────────
show_help() {
    printf "%b\n" "$(cat << EOF
${BOLD}process-tree.sh${RESET} — Rebuild Rojo tree and sourcemap

${BOLD}DESCRIPTION${RESET}
    Runs the two steps needed after changing source files:
      1. Generate default.project.json  (generateRojoTree.js)
      2. Generate sourcemap.json        (rojo sourcemap)

    Type generation is intentionally excluded. wally-package-types mutates
    Packages/ in place — running it again on already-mutated files breaks
    them. Types must only run right after a fresh wally install.
    Use install-packages.sh or setup.sh for that.

${BOLD}USAGE${RESET}
    sh scripts/process-tree.sh [OPTIONS]

${BOLD}OPTIONS${RESET}
    --skip-tree     Skip step 1 (reuse existing default.project.json)
    --skip-map      Skip step 2
    --watch         Keep watching relevant project files and rerun on changes
    --debounce-ms   Debounce delay in milliseconds for watch mode (default: 250)
    --help, -h      Show this help

${BOLD}REQUIREMENTS${RESET}
    - node
    - rojo

EOF
)"
}

# ── Parse args ────────────────────────────────────────────────
SKIP_TREE=false
SKIP_MAP=false
WATCH=false
DEBOUNCE_MS=250

while [ $# -gt 0 ]; do
    case "$1" in
    --skip-tree)  SKIP_TREE=true ;;
    --skip-map)   SKIP_MAP=true ;;
    --watch)      WATCH=true ;;
    --debounce-ms)
        shift
        if [ $# -eq 0 ]; then
            print_error "--debounce-ms requires a value"
            exit 1
        fi
        DEBOUNCE_MS="$1"
        ;;
    --debounce-ms=*)
        DEBOUNCE_MS=${1#*=}
        ;;
    --help|-h)    show_help; exit 0 ;;
    *)
        print_error "Unknown option: $1"
        echo "Use --help for usage"
        exit 1
        ;;
    esac
    shift
done

case "$DEBOUNCE_MS" in
    ''|*[!0-9]*)
        print_error "--debounce-ms must be a non-negative integer"
        exit 1
        ;;
esac

run_tree_step() {
    if ! command_exists node; then
        print_error "node is not installed"
        return 1
    fi

    print_step "Generating Rojo project tree..."
    if node scripts/generateRojoTree.js; then
        print_success "default.project.json generated"
    else
        print_error "Tree generation failed"
        return 1
    fi
}

run_map_step() {
    if ! command_exists rojo; then
        print_error "rojo is not installed"
        return 1
    fi

    print_step "Generating sourcemap..."
    if rojo sourcemap default.project.json --output sourcemap.json; then
        print_success "sourcemap.json generated"
    else
        print_error "Sourcemap generation failed"
        return 1
    fi
}

run_once() {
    if [ "$SKIP_TREE" = "false" ]; then
        run_tree_step || return 1
        echo ""
    else
        if [ ! -f "default.project.json" ]; then
            print_error "--skip-tree was set but default.project.json does not exist"
            return 1
        fi
        print_info "Skipping tree generation (--skip-tree)"
    fi

    if [ "$SKIP_MAP" = "false" ]; then
        run_map_step || return 1
        echo ""
    else
        print_info "Skipping sourcemap generation (--skip-map)"
    fi

    print_success "Tree processing complete!"
}

watch_loop() {
    if [ "$SKIP_TREE" = "true" ] && [ "$SKIP_MAP" = "true" ]; then
        print_error "--watch has nothing to do when both --skip-tree and --skip-map are set"
        return 1
    fi

    PROJECT_ROOT=$(pwd)
    export PROJECT_ROOT SKIP_TREE SKIP_MAP DEBOUNCE_MS

    print_info "Watching for source/config changes. Press Ctrl+C to stop."

    node <<'EOF'
    const fs = require("fs");
    const path = require("path");
    const { spawn } = require("child_process");

    const projectRoot = process.env.PROJECT_ROOT;
    const skipTree = process.env.SKIP_TREE === "true";
    const skipMap = process.env.SKIP_MAP === "true";
    const debounceMs = Number.parseInt(process.env.DEBOUNCE_MS || "250", 10);

    const watchTargets = [];

    function addWatchTarget(kind, relativePath, options = {}) {
        const absolutePath = path.join(projectRoot, relativePath);
        if (!fs.existsSync(absolutePath)) return;
        watchTargets.push({ kind, relativePath, absolutePath, options });
    }

    if (!skipTree) {
        addWatchTarget("dir", "src", { recursive: true });
        addWatchTarget("file", "game.toml");
    } else if (!skipMap) {
        addWatchTarget("file", "default.project.json");
    }

    if (watchTargets.length === 0) {
        console.error("No existing watch targets found.");
        process.exit(1);
    }

    function normalizeRelative(filePath) {
        return filePath.split(path.sep).join("/");
    }

    function shouldIgnore(relativePath) {
        if (!relativePath) return false;
        const baseName = path.basename(relativePath);
        return (
            baseName === ".DS_Store" ||
            baseName.endsWith("~") ||
            baseName.endsWith(".tmp") ||
            baseName.endsWith(".swp") ||
            baseName.endsWith(".swo") ||
            baseName.endsWith(".bak") ||
            baseName.startsWith(".#")
        );
    }

    let timer = null;
    let running = false;
    let pending = false;
    let pendingReason = null;
    let child = null;

    function queueRun(reason) {
        pendingReason = reason || pendingReason || "changes";

        if (running) {
            pending = true;
            return;
        }

        if (timer !== null) clearTimeout(timer);
        timer = setTimeout(() => {
            timer = null;
            const nextReason = pendingReason || "changes";
            pendingReason = null;
            runProcess(nextReason);
        }, debounceMs);
    }

    function runProcess(reason) {
        running = true;
        console.log(`\n[watch] Reprocessing after ${reason}`);

        const args = ["scripts/process-tree.sh"];
        if (skipTree) args.push("--skip-tree");
        if (skipMap) args.push("--skip-map");

        child = spawn("sh", args, {
            cwd: projectRoot,
            stdio: "inherit",
            env: process.env,
        });

        child.on("exit", (code, signal) => {
            running = false;
            child = null;

            if (signal) {
                console.log(`[watch] Process interrupted by ${signal}`);
            } else if (code !== 0) {
                console.log(`[watch] Process exited with code ${code}`);
            }

            if (pending) {
                pending = false;
                queueRun(pendingReason || "additional changes");
            }
        });
    }

    const watchers = watchTargets.map((target) => {
        try {
            return fs.watch(target.absolutePath, target.options, (_eventType, filename) => {
                const relativePath = filename
                    ? normalizeRelative(path.join(target.relativePath, String(filename)))
                    : target.relativePath;

                if (shouldIgnore(relativePath)) return;
                queueRun(relativePath);
            });
        } catch (error) {
            console.error(`Failed to watch ${target.relativePath}: ${error.message}`);
            process.exit(1);
        }
    });

    function shutdown() {
        if (timer !== null) clearTimeout(timer);
        for (const watcher of watchers) watcher.close();
        if (child) child.kill("SIGINT");
        process.exit(0);
    }

    process.on("SIGINT", shutdown);
    process.on("SIGTERM", shutdown);
EOF
}

# ── Main ──────────────────────────────────────────────────────
cd "$(dirname "$0")/.."

if [ "$WATCH" = "true" ]; then
    if run_once; then
        echo ""
    else
        print_warning "Initial processing failed. Watch mode will stay active so you can fix files and retry on save."
        echo ""
    fi
    watch_loop
else
    run_once
fi