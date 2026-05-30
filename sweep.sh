#!/usr/bin/env bash
set -euo pipefail

# sweep — Safe disk cleanup for AI agents
# Whitelist-based: only touches paths explicitly defined here.

VERSION="0.4.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=true
MIN_FILE_AGE_HOURS=24
PREVIEW_TTL_SECONDS=1800

# ── Platform detection ──────────────────────────────────────────────
detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}

OS=$(detect_os)

# ── Category definitions ────────────────────────────────────────────
# Format: "tag|path|description|recursive_size"
# tag: safe | caution | manual
get_categories() {
    if [[ "$OS" == "macos" ]]; then
        cat <<'CATEGORIES'
safe|~/Library/Caches|User caches (non-Apple)|1
safe|~/Library/Developer/Xcode/DerivedData|Xcode derived data|1
safe|~/Library/Developer/Xcode/iOS DeviceSupport|iOS device support files|1
safe|~/Library/Developer/CoreSimulator/Caches|Simulator caches|1
safe|~/.Trash|Trash|1
safe|~/.npm/_cacache|npm cache|1
safe|~/.cache|User cache|1
safe|~/Library/Application Support/Code/Cache|VS Code cache|1
safe|~/Library/Application Support/Code/CachedData|VS Code cached data|1
safe|~/Library/Application Support/Code/User/workspaceStorage|VS Code workspace storage|1
safe|~/Library/Application Support/Cursor/Cache|Cursor cache|1
safe|~/Library/Application Support/Cursor/CachedData|Cursor cached data|1
safe|~/.gradle/caches|Gradle caches|1
safe|~/.cargo/registry/cache|Cargo registry cache|1
safe|~/Library/Group Containers/*.com.apple.notes/Accounts/LocalAccount/Media|Apple Notes media|1
safe|~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads|Mail downloads|1
caution|~/Downloads|Downloads folder|1
caution|~/Library/Logs|System and app logs|1
CATEGORIES
    elif [[ "$OS" == "linux" ]]; then
        cat <<'CATEGORIES'
safe|~/.cache|User cache|1
safe|/tmp|Temp files (older than 1 day)|1
safe|~/.npm/_cacache|npm cache|1
safe|~/.gradle/caches|Gradle caches|1
safe|~/.cargo/registry/cache|Cargo registry cache|1
safe|~/.local/share/Trash|Trash|1
caution|/var/tmp|System temp (older than 3 days)|1
caution|~/.local/share/containers/storage|Podman container storage|1
CATEGORIES
    fi
}

# ── Helpers ─────────────────────────────────────────────────────────
expand_path() {
    local p="$1"
    # Expand ~ and globs
    p="${p/#\~/$HOME}"
    # Return literal if no glob; expanded list otherwise
    if [[ "$p" == *"*"* ]]; then
        compgen -G "$p" || echo "$p"
    else
        echo "$p"
    fi
}

format_size() {
    local bytes=$1
    if command -v numfmt &>/dev/null; then
        numfmt --to=iec --suffix=B "$bytes"
    else
        if (( bytes > 1073741824 )); then
            echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1073741824}") GB"
        elif (( bytes > 1048576 )); then
            echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}") MB"
        elif (( bytes > 1024 )); then
            echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1024}") KB"
        else
            echo "${bytes} B"
        fi
    fi
}

du_bytes() {
    local p="$1"
    local kb

    kb=$(du -sk "$p" 2>/dev/null | awk 'NR == 1 {print $1}')
    if [[ ! "$kb" =~ ^[0-9]+$ ]]; then
        echo 0
        return
    fi

    echo $((kb * 1024))
}

du_human() {
    format_size "$(du_bytes "$1")"
}

hash_stdin() {
    if command -v shasum &>/dev/null; then
        shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum &>/dev/null; then
        sha256sum | awk '{print $1}'
    elif command -v openssl &>/dev/null; then
        openssl dgst -sha256 | awk '{print $NF}'
    else
        cksum | awk '{printf "%016x\n", $1}'
    fi
}

terminal_cols() {
    if [[ -n "${TERM:-}" ]] && command -v tput &>/dev/null; then
        tput cols 2>/dev/null || echo 80
    else
        echo 80
    fi
}

should_skip_target() {
    local raw_path="$1"
    local target="$2"
    local base

    base="$(basename "$target")"
    if [[ "$OS" == "macos" ]] && [[ "$raw_path" == "~/Library/Caches" ]]; then
        case "$base" in
            com.apple.*|CloudKit|GeoServices|PassKit|GameKit|FamilyCircle|familycircled|Animoji|ARFileCache|LSMImageCache|SharedImageCache|sportsd|askpermissiond|TrickPlay|tvapp_bag|features_config)
                return 0
                ;;
        esac
    fi

    return 1
}

collect_delete_targets() {
    local raw_path="$1"
    local outfile="$2"
    local target

    : > "$outfile"

    while IFS= read -r p; do
        if [[ ! -e "$p" ]]; then
            continue
        fi

        if [[ -d "$p" ]]; then
            while IFS= read -r -d '' target; do
                should_skip_target "$raw_path" "$target" && continue
                printf '%s\0' "$target" >> "$outfile"
            done < <(find "$p" -mindepth 1 -maxdepth 1 -print0 2>/dev/null || true)
        else
            should_skip_target "$raw_path" "$p" && continue
            printf '%s\0' "$p" >> "$outfile"
        fi
    done < <(expand_path "$raw_path")
}

manifest_digest() {
    local manifest="$1"

    hash_stdin < "$manifest"
}

manifest_count() {
    local manifest="$1"

    tr -cd '\0' < "$manifest" | wc -c | tr -d ' '
}

manifest_total_bytes() {
    local manifest="$1"
    local total=0
    local target size

    while IFS= read -r -d '' target; do
        if [[ -e "$target" ]]; then
            size=$(du_bytes "$target")
            total=$((total + size))
        fi
    done < "$manifest"

    echo "$total"
}

manifest_recent_file_count() {
    local manifest="$1"
    local target count=0

    while IFS= read -r -d '' target; do
        if [[ ! -e "$target" ]]; then
            continue
        fi

        if [[ -d "$target" ]]; then
            count=$((count + $(find "$target" -type f -mmin "-$((MIN_FILE_AGE_HOURS * 60))" 2>/dev/null | wc -l | tr -d ' ')))
        elif [[ -f "$target" ]]; then
            if find "$target" -type f -mmin "-$((MIN_FILE_AGE_HOURS * 60))" 2>/dev/null | grep -q .; then
                count=$((count + 1))
            fi
        fi
    done < "$manifest"

    echo "$count"
}

print_manifest_targets() {
    local manifest="$1"
    local target size

    echo "   Full manifest:"
    while IFS= read -r -d '' target; do
        if [[ -e "$target" ]]; then
            size=$(du_human "$target")
        else
            size="missing"
        fi
        printf "     %-10s %s\n" "$size" "$target"
    done < "$manifest"
}

preview_state_dir() {
    local dir="${TMPDIR:-/tmp}/sweep-previews-${UID}"
    mkdir -p "$dir"
    chmod 700 "$dir" 2>/dev/null || true
    echo "$dir"
}

preview_token_file() {
    local token="$1"

    if [[ ! "$token" =~ ^[a-f0-9]{16}$ ]]; then
        return 1
    fi

    echo "$(preview_state_dir)/$token"
}

preview_manifest_file() {
    local token="$1"
    local file

    file=$(preview_token_file "$token") || return 1
    echo "$file.targets"
}

write_preview_state() {
    local desc="$1"
    local tag="$2"
    local digest="$3"
    local target_count="$4"
    local now expires token file

    now=$(date +%s)
    expires=$((now + PREVIEW_TTL_SECONDS))
    token=$(printf '%s|%s|%s|%s|%s\n' "$desc" "$tag" "$digest" "$now" "$$" | hash_stdin | awk '{print substr($1, 1, 16)}')
    file=$(preview_token_file "$token")

    {
        echo "version=1"
        echo "created_at=$now"
        echo "expires_at=$expires"
        echo "category=$desc"
        echo "tag=$tag"
        echo "manifest_digest=$digest"
        echo "target_count=$target_count"
    } > "$file"
    chmod 600 "$file" 2>/dev/null || true

    echo "$token"
}

read_preview_field() {
    local file="$1"
    local key="$2"

    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

validate_preview_token() {
    local token="$1"
    local expected_desc="$2"
    local file manifest now expires category expected_digest actual_digest expected_count actual_count

    if [[ -z "$token" ]]; then
        echo "❌ Missing preview token."
        echo "   Run 'sweep preview \"$expected_desc\"' first, then pass the printed token:"
        echo "   sweep clean \"$expected_desc\" --yes --preview-token <token>"
        return 1
    fi

    if ! file=$(preview_token_file "$token"); then
        echo "❌ Invalid preview token format."
        return 1
    fi

    if [[ ! -f "$file" ]]; then
        echo "❌ Preview token not found or already used."
        echo "   Run 'sweep preview \"$expected_desc\"' again."
        return 1
    fi

    manifest=$(preview_manifest_file "$token")
    if [[ ! -f "$manifest" ]]; then
        echo "❌ Preview manifest not found or already used."
        echo "   Run 'sweep preview \"$expected_desc\"' again."
        return 1
    fi

    now=$(date +%s)
    expires=$(read_preview_field "$file" "expires_at")
    category=$(read_preview_field "$file" "category")
    expected_digest=$(read_preview_field "$file" "manifest_digest")
    expected_count=$(read_preview_field "$file" "target_count")

    if [[ ! "$expires" =~ ^[0-9]+$ ]] || (( now > expires )); then
        echo "❌ Preview token expired."
        echo "   Run 'sweep preview \"$expected_desc\"' again."
        return 1
    fi

    if [[ "$category" != "$expected_desc" ]]; then
        echo "❌ Preview token was created for '$category', not '$expected_desc'."
        return 1
    fi

    actual_digest=$(manifest_digest "$manifest")
    if [[ "$actual_digest" != "$expected_digest" ]]; then
        echo "❌ Preview manifest changed since the token was created."
        echo "   Run 'sweep preview \"$expected_desc\"' again."
        return 1
    fi

    actual_count=$(manifest_count "$manifest")
    if [[ ! "$expected_count" =~ ^[0-9]+$ ]] || [[ "$actual_count" != "$expected_count" ]]; then
        echo "❌ Preview manifest item count changed since the token was created."
        echo "   Run 'sweep preview \"$expected_desc\"' again."
        return 1
    fi
}

is_allowed_target() {
    local target="$1"
    local raw_path="$2"
    local root

    while IFS= read -r root; do
        if [[ ! -e "$root" ]]; then
            continue
        fi

        if [[ -d "$root" ]]; then
            case "$target" in
                "$root"/*) return 0 ;;
            esac
        elif [[ "$target" == "$root" ]]; then
            return 0
        fi
    done < <(expand_path "$raw_path")

    return 1
}

validate_manifest_targets() {
    local manifest="$1"
    local raw_path="$2"
    local target count=0

    while IFS= read -r -d '' target; do
        count=$((count + 1))

        if [[ -z "$target" ]] || [[ "$target" == "/" ]]; then
            echo "❌ Refusing unsafe empty/root manifest target."
            return 1
        fi

        if [[ "$target" != /* ]] || [[ "$target" == *"/../"* ]] || [[ "$target" == */.. ]]; then
            echo "❌ Refusing unsafe manifest target:"
            echo "   $target"
            return 1
        fi

        if ! is_allowed_target "$target" "$raw_path"; then
            echo "❌ Manifest target is outside the selected whitelist category:"
            echo "   $target"
            return 1
        fi
    done < "$manifest"

    if (( count == 0 )); then
        echo "❌ Preview manifest is empty."
        echo "   Nothing to clean."
        return 1
    fi
}

clean_manifest_targets() {
    local manifest="$1"
    local deleted=0
    local missing=0
    local total_bytes=0
    local target size

    while IFS= read -r -d '' target; do
        if [[ ! -e "$target" ]]; then
            missing=$((missing + 1))
            continue
        fi

        size=$(du_bytes "$target")
        total_bytes=$((total_bytes + size))
        echo "🧹 Permanently deleting: $target ($(format_size "$size"))"
        rm -rf -- "$target"
        deleted=$((deleted + 1))
    done < "$manifest"

    echo "✅ Done. Deleted $deleted item(s), skipped $missing missing item(s)."
    echo "   Freed approximately $(format_size "$total_bytes")."
}

consume_preview_token() {
    local token="$1"
    local file manifest

    file=$(preview_token_file "$token") || return 0
    manifest=$(preview_manifest_file "$token") || return 0
    rm -f "$file"
    rm -f "$manifest"
}

# ── Analyze ─────────────────────────────────────────────────────────
cmd_analyze() {
    echo "🔍 Sweep disk analysis"
    echo "Platform: $OS"
    echo ""

    local total_reclaimable=0
    local results=()

    while IFS='|' read -r tag path desc recursive; do
        local manifest_tmp size target_count
        manifest_tmp=$(mktemp "$(preview_state_dir)/analyze.XXXXXX")
        collect_delete_targets "$path" "$manifest_tmp"
        target_count=$(manifest_count "$manifest_tmp")

        if (( target_count == 0 )); then
            rm -f "$manifest_tmp"
            continue
        fi

        size=$(manifest_total_bytes "$manifest_tmp")
        rm -f "$manifest_tmp"

        if (( size < 1048576 )); then  # Skip < 1MB
            continue
        fi

        local human_size
        human_size=$(format_size "$size")
        results+=("$(printf "%-12s %-50s %s" "$human_size" "$desc" "$tag")")

        if [[ "$tag" == "safe" ]]; then
            total_reclaimable=$((total_reclaimable + size))
        fi
    done < <(get_categories)

    printf "%-12s %-50s %s\n" "Size" "Category" "Tag"
    printf "%$(terminal_cols)s\n" | tr ' ' '─'
    for r in "${results[@]}"; do
        echo "$r"
    done

    echo ""
    echo "Total reclaimable (safe): $(format_size $total_reclaimable)"
    echo ""
    echo "Run 'sweep preview <category>' to see files and get a token."
    echo "Destructive cleanup requires: sweep clean <category> --yes --preview-token <token>"
}

# ── Preview ─────────────────────────────────────────────────────────
cmd_preview() {
    local target_desc="$1"
    local found=false

    while IFS='|' read -r tag path desc recursive; do
        if [[ "$desc" != "$target_desc" ]]; then
            continue
        fi
        found=true

        local matched_path=false

        while IFS= read -r p; do
            if [[ ! -e "$p" ]]; then
                echo "Path not found: $p"
                continue
            fi
            matched_path=true

            local size
            size=$(du_human "$p")

            echo "📁 $desc ($tag)"
            echo "   Path: $p"
            echo "   Raw path size: $size"
            echo ""

            if [[ "$tag" == "manual" ]]; then
                echo "⚠️  This category is tagged 'manual' — sweep will not clean it."
                echo "   Use 'ls -la $p' to inspect manually."
                return
            fi
        done < <(expand_path "$path")

        if [[ "$tag" != "manual" ]] && $matched_path; then
            local manifest_tmp target_count total_bytes token digest manifest
            manifest_tmp=$(mktemp "$(preview_state_dir)/targets.XXXXXX")
            collect_delete_targets "$path" "$manifest_tmp"
            target_count=$(manifest_count "$manifest_tmp")

            if (( target_count == 0 )); then
                rm -f "$manifest_tmp"
                echo ""
                echo "   No top-level items to clean."
                continue
            fi

            total_bytes=$(manifest_total_bytes "$manifest_tmp")
            digest=$(manifest_digest "$manifest_tmp")
            token=$(write_preview_state "$desc" "$tag" "$digest" "$target_count")
            manifest=$(preview_manifest_file "$token")
            mv "$manifest_tmp" "$manifest"
            chmod 600 "$manifest" 2>/dev/null || true

            echo ""
            echo "   Manifest items: $target_count"
            echo "   Manifest size: $(format_size "$total_bytes")"
            print_manifest_targets "$manifest"
            echo "   Preview token: $token"
            echo "   Valid for: $((PREVIEW_TTL_SECONDS / 60)) minutes"
            echo "   After explicit confirmation, run:"
            echo "   sweep clean \"$desc\" --yes --preview-token $token"
        fi
    done < <(get_categories)

    if ! $found; then
        echo "Unknown category: $target_desc"
        echo "Available categories:"
        get_categories | while IFS='|' read -r _ _ desc _; do
            echo "  - $desc"
        done
        return 1
    fi
}

# ── Clean ───────────────────────────────────────────────────────────
cmd_clean() {
    local target_desc="$1"
    local found=false
    shift || true

    # Parse --yes flag
    local force=false
    local preview_token=""
    for arg in "$@"; do
        case "$arg" in
            --yes|-y)
                force=true
                ;;
            --preview-token=*)
                preview_token="${arg#--preview-token=}"
                ;;
        esac
    done

    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--preview-token" ]]; then
            if [[ $# -lt 2 ]]; then
                echo "Missing value for --preview-token"
                return 1
            fi
            preview_token="$2"
            shift 2
            continue
        fi
        shift
    done

    while IFS='|' read -r tag path desc recursive; do
        if [[ "$desc" != "$target_desc" ]]; then
            continue
        fi
        found=true

        if [[ "$tag" == "manual" ]]; then
            echo "❌ Refusing to clean '$desc' — tagged as manual."
            echo "   Inspect manually and delete explicitly."
            return 1
        fi

        local manifest

        if $force; then
            validate_preview_token "$preview_token" "$desc" || return 1
            manifest=$(preview_manifest_file "$preview_token")
            validate_manifest_targets "$manifest" "$path" || return 1

            local recent_count
            recent_count=$(manifest_recent_file_count "$manifest")
            if [[ "$recent_count" -gt 0 ]]; then
                echo "⚠️  $recent_count file(s) in the preview manifest were modified within ${MIN_FILE_AGE_HOURS}h."
                echo "   Refusing cleanup. Inspect manually or try again later."
                return 1
            fi
        fi

        while IFS= read -r p; do
            if [[ ! -e "$p" ]]; then
                echo "Path not found: $p"
                continue
            fi

            local size
            size=$(du_human "$p")

            if ! $force; then
                echo "🧹 Would clean previewed top-level items under: $p ($size)"
                echo "   Parent directory would be preserved."
                echo ""
                echo "   This is a dry run. Run preview to get a token before deleting:"
                echo "   sweep preview \"$target_desc\""
                return 0
            fi
        done < <(expand_path "$path")

        if $force; then
            clean_manifest_targets "$manifest"
            consume_preview_token "$preview_token"
        fi
    done < <(get_categories)

    if ! $found; then
        echo "Unknown category: $target_desc"
        get_categories | while IFS='|' read -r _ _ desc _; do
            echo "  - $desc"
        done
        return 1
    fi
}

# ── Docker extras ───────────────────────────────────────────────────
cmd_docker() {
    if ! command -v docker &>/dev/null; then
        echo "Docker not installed."
        return 0
    fi

    echo "🐳 Docker disk usage:"
    docker system df 2>/dev/null || echo "Cannot connect to Docker daemon."
    echo ""

    echo "Reclaimable:"
    echo "  docker system prune --all --force      # Remove unused images, containers, networks"
    echo "  docker builder prune --all --force     # Remove build cache"
    echo "  docker volume prune --force            # Remove unused volumes"
}

# ── Main ────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-analyze}"
    shift || true

    case "$cmd" in
        analyze|check|scan)
            cmd_analyze
            ;;
        preview|show|inspect)
            if [[ $# -lt 1 ]]; then
                echo "Usage: sweep preview <category>"
                echo "Run 'sweep analyze' first to see categories."
                exit 1
            fi
            cmd_preview "$*"
            ;;
        clean|clear|delete)
            if [[ $# -lt 1 ]]; then
                echo "Usage: sweep clean <category> [--yes]"
                echo "Run 'sweep preview <category>' first."
                exit 1
            fi
            cmd_clean "$@"
            ;;
        docker|docker-df)
            cmd_docker
            ;;
        version|--version|-v)
            echo "sweep v$VERSION"
            ;;
        help|--help|-h)
            cat <<EOF
sweep — Safe disk cleanup

Usage:
  sweep analyze              Show disk usage by category
  sweep preview <category>   Show files in a category
  sweep clean <category>     Dry-run cleanup for a category
  sweep clean <category> --yes --preview-token <token>
                             Delete files after a fresh preview token
  sweep docker               Show Docker disk usage
  sweep version              Print version

Categories are whitelist-only. Run 'sweep analyze' and 'sweep preview' first.
EOF
            ;;
        *)
            echo "Unknown command: $cmd"
            echo "Run 'sweep help' for usage."
            exit 1
            ;;
    esac
}

main "$@"
