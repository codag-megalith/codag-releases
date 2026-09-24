# Codag releases

This public repository contains installers and compiled release artifacts.
The current product is **Codag log MCP**, built from `codag-megalith/codag`.
The engine source remains private. No GitHub login is needed to install a release.

Install on macOS or Linux (arm64 or amd64):

```sh
curl -fsSL https://codag.ai/install.sh | sh
# The installer opens setup automatically in a terminal. To run it again:
codag-log-mcp setup
```

The script installs `~/.local/bin/codag-log-mcp`, then asks for a CSV/TSV log file
and your agent (Codex, Claude Code, OpenCode, or generic config). It needs no Rust,
Git, Make, Python, account, or separate model key. Your agent handles model access.
Linux binaries are statically linked with musl. macOS binaries target macOS 11+.

`install-log-engine.sh` reads `log-latest.txt`, which points only to a verified
`log-vX.Y.Z` release. It verifies the archive's SHA-256 before replacing an existing
binary. Downloads and setup do not send log contents anywhere. Setup uses the
existing client CLI only after confirmation (or explicit `--apply`).

Use `CODAG_INSTALL_DIR` for another install directory, `CODAG_LOG_VERSION` for a
specific release, or `CODAG_SKIP_SETUP=1` for unattended installation. Set these
on `sh`, for example:

```sh
curl -fsSL https://codag.ai/install.sh | CODAG_SKIP_SETUP=1 sh
~/.local/bin/codag-log-mcp setup --log-file /absolute/path/logs.csv --client codex --apply
```

The **Publish log engine** workflow builds and tests all four platforms from an
exact source commit and dependency commit, then publishes checksums, GitHub
attestations, and `provenance.json`. Only after all builds and installer tests
pass does it advance `log-latest.txt`. `codag-log-mcp --version` reports its source
commit. Release versions are immutable; increment the MCP package version for
each new release. To publish current main:

```sh
./release-log.sh 0.1.0
```

The script resolves current source and dependency HEADs once, dispatches the
workflow with those exact commits, and prints the Actions URL. Review the workflow
result before announcing a release. A source commit alone does not release an
update to users.

The installer requires `curl`, `tar`, and either `sha256sum` or `shasum`.
`CODAG_REQUIRE_ATTESTATION=1` additionally verifies GitHub's build attestation and
requires GitHub CLI. SHA-256 verification always runs.

The previous account-based CLI remains under `vX.Y.Z` releases and `install.sh`
in this repository, accessible through `https://codag.ai/install-cli.sh`.
The log engine never selects GitHub's mixed-product `releases/latest` endpoint.
