---
name: sweep
description: |
  Safe disk cleanup workflow for AI agents. Use when the user asks to free disk
  space, clean caches, analyze disk usage, clear build artifacts, or reclaim
  storage on macOS/Linux with preview-token confirmation.
metadata:
  short-description: Safe disk cleanup
---

# Sweep — Safe Disk Cleanup for AI Agents

Analyze disk usage by category, then clean with user-confirmed whitelist-based deletion.

## When to Use

- The user asks to "free up space", "clean my disk", "clear caches", "reclaim storage"
- Disk usage is above 85% and the user wants to investigate
- Before a large install or download that needs headroom

## Workflow

### Phase 1 — Analyze

Run `./sweep.sh analyze` to get a categorized breakdown of disk usage. Each category is tagged:

| Tag | Meaning |
|-----|---------|
| `safe` | Managed caches, derived data, build artifacts — safe to delete |
| `caution` | Logs, downloads, Trash — usually safe but worth a glance |
| `manual` | User data, configs, projects — present for context but never auto-clean |

### Phase 2 — Review

Present findings to the user as a table:

```
Category              Size      Tag
─────────────────────────────────────────
Xcode DerivedData     12.3 GB   safe
npm caches            4.1 GB    safe
Docker dangling       3.8 GB    safe
~/Downloads           8.2 GB    caution
~/Library/Logs        2.1 GB    caution
System Trash          1.5 GB    safe
```

Ask the user which categories they want to clean. Recommend `safe` tagged items by default.

### Phase 3 — Preview & Confirm

For each category the user selects, run `./sweep.sh preview <category>` to show exact files and sizes. The preview prints a short-lived token. After the user explicitly confirms that preview, run:

```
./sweep.sh clean <category> --yes --preview-token <token>
```

Never invent or reuse a preview token. If the token is missing, expired, or rejected, run preview again and ask for confirmation again.

Cleanup is permanent and manifest-based: the script deletes only the top-level items captured by `preview`, preserves the whitelisted parent directory, and does not move items to Trash.

## Guardrails

- **Whitelist only.** The script only touches paths explicitly listed in the safe/caution categories below. It cannot delete arbitrary files.
- **Preview before delete.** Every destructive `clean --yes` requires a fresh preview token from a preceding `preview`.
- **Manifest-only deletion.** `clean --yes` deletes only the top-level items captured by `preview`, not newly created items and not the whitelisted parent directory.
- **Recent-file protection.** If any file in the preview manifest was modified within the last 24 hours, `clean --yes` refuses the whole cleanup, including `safe` categories.
- **No `rm -rf` on user data.** `manual` tagged categories are read-only and the script will refuse to clean them.
- **Dry-run by default.** The `clean` command prints what it would do and asks for final `--yes` flag plus preview token.
- **Permanent cleanup.** Deletion is direct, not moved to Trash, so cleanup actually reclaims disk space.

## Safe-to-delete Paths

### macOS
| Path | Category |
|------|----------|
| `~/Library/Caches` (non-Apple subdirs) | safe |
| `~/Library/Developer/Xcode/DerivedData` | safe |
| `~/Library/Developer/Xcode/iOS DeviceSupport` | safe |
| `~/Library/Developer/CoreSimulator/Caches` | safe |
| `~/.Trash` | safe |
| `~/.npm/_cacache` | safe |
| `~/.cache` | safe |
| `~/Library/Application Support/Code/Cache` | safe |
| `~/Library/Application Support/Code/CachedData` | safe |
| `~/Library/Application Support/Code/User/workspaceStorage` | safe |
| `~/Library/Application Support/Cursor/Cache` | safe |
| `~/Library/Application Support/Cursor/CachedData` | safe |
| `~/.gradle/caches` | safe |
| `~/.cargo/registry/cache` | safe |
| `~/Library/Group Containers/*.com.apple.notes/Accounts/LocalAccount/Media` | safe |
| `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` | safe |

### macOS Caution
| Path | Category |
|------|----------|
| `~/Downloads` | caution |
| `~/Library/Logs` | caution |
| `~/.Trash` | safe |

### Linux
| Path | Category |
|------|----------|
| `~/.cache` (non-essential subdirs) | safe |
| `/tmp` (files older than 1 day) | safe |
| `~/.npm/_cacache` | safe |
| `~/.gradle/caches` | safe |
| `~/.cargo/registry/cache` | safe |
| `~/.local/share/Trash` | safe |
| `/var/tmp` (files older than 3 days) | caution |
| `~/.local/share/containers/storage` (podman) | safe |

## Never Touch

- `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config` (credentials/config)
- `~/.gitconfig`, `~/.git-credentials`
- Any path with `node_modules` inside a project (use `npkill` instead)
- System paths outside `~/Library` on macOS (except `/tmp` on Linux)
- Any file younger than 24 hours in cache directories
- `~/Documents`, `~/Desktop`, `~/Pictures`, `~/Movies`
- Any git repository directory
