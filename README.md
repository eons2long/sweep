# sweep

Safe disk cleanup for AI agents — analyze what's taking space, then clean with whitelist-based deletion.

## Why

Giving an AI agent `rm -rf` is terrifying. `sweep` constrains disk cleanup to a curated whitelist of safe-to-delete paths, always previews before deleting, and requires explicit `--yes` confirmation with a fresh preview token.

## Quick Start

```bash
# 1. Analyze
./sweep.sh analyze

# 2. Preview a category
./sweep.sh preview "Xcode derived data"

# 3. Clean (dry run first)
./sweep.sh clean "Xcode derived data"

# 4. Clean with confirmation and the preview token printed above
./sweep.sh clean "Xcode derived data" --yes --preview-token <token>
```

## Supported Platforms

- **macOS** — Xcode, VS Code, Cursor, npm, Gradle, Cargo, Simulator, Mail, Notes caches
- **Linux** — npm, Gradle, Cargo, Podman, system temp files, Trash

## Safety Design

| Mechanism | What it does |
|-----------|-------------|
| **Whitelist-only** | Only touches paths explicitly defined in the script |
| **Preview first** | Shows exact files and sizes before deletion |
| **Preview token** | `clean --yes` requires a fresh token from `preview` |
| **Manifest-only delete** | Deletes only the top-level items captured by preview, preserving the whitelisted parent directory |
| **--yes gate** | Dry-run by default; destructive cleanup requires explicit confirmation plus token |
| **Permanent cleanup** | Deletes manifest items directly instead of moving them to Trash, so disk space is actually reclaimed |
| **Min file age** | Won't touch manifest files modified in the last 24h, including `safe` categories |
| **Tag system** | `safe` / `caution` / `manual` — manual is read-only |

## As a Codex or Claude Code Skill

`sweep` includes a `SKILL.md` that instructs Codex or Claude Code how to use the analysis and cleanup workflow safely. When invoked, the AI will:

1. Run `sweep analyze` to get a categorized breakdown
2. Present findings to you as a table
3. Only clean categories you explicitly approve
4. Preview before every deletion and pass the fresh preview token to `clean --yes`

The skill can also be installed into Codex as a local skill directory. The repository is the source; the tool is active only after the `SKILL.md` and executable `sweep.sh` are placed in the agent's configured skills directory.

## Install

Just clone and make executable:

```bash
git clone https://github.com/eons2long/sweep.git
cd sweep
chmod +x sweep.sh
```

Optionally symlink `sweep.sh` into your PATH:

```bash
ln -s "$(pwd)/sweep.sh" /usr/local/bin/sweep
```

## License

MIT
