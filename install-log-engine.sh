#!/bin/sh
# Current log engine only. The older account-based CLI uses install.sh here.
set -eu

main() {
    release_repo=codag-megalith/codag-releases
    install_dir=${CODAG_INSTALL_DIR:-${HOME:?Set HOME or CODAG_INSTALL_DIR}/.local/bin}
    version=${CODAG_LOG_VERSION:-}
    skip_setup=${CODAG_SKIP_SETUP:-0}
    for arg in "$@"; do
        case "$arg" in
            --no-setup) skip_setup=1 ;;
            --help|-h)
                printf 'Install Codag log MCP: curl -fsSL https://codag.ai/install.sh | sh\n\nCODAG_INSTALL_DIR chooses the binary directory (default: ~/.local/bin).\nCODAG_LOG_VERSION pins a log-vX.Y.Z release.\nCODAG_SKIP_SETUP=1 skips interactive agent setup.\nCODAG_REQUIRE_ATTESTATION=1 also requires verification with GitHub CLI.\n'
                return ;;
            *) fail "Unknown option: $arg" ;;
        esac
    done
    for command in curl tar mktemp; do
        command -v "$command" >/dev/null 2>&1 || fail "$command is required"
    done
    if command -v sha256sum >/dev/null 2>&1; then
        checksum_tool=sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        checksum_tool=shasum
    else
        fail 'A SHA-256 tool (sha256sum or shasum) is required'
    fi
    case "$(uname -s)" in
        Darwin) os=darwin ;;
        Linux) os=linux ;;
        *) fail 'Supported platforms: macOS and Linux, arm64 and amd64' ;;
    esac
    case "$(uname -m)" in
        arm64|aarch64) arch=arm64 ;;
        x86_64|amd64) arch=amd64 ;;
        *) fail 'Supported architectures: arm64 and amd64' ;;
    esac
    temp_dir=$(mktemp -d)
    install_temp=
    trap 'rm -rf "$temp_dir"; if [ -n "$install_temp" ]; then rm -f "$install_temp"; fi' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ -z "$version" ]; then
        download "https://raw.githubusercontent.com/$release_repo/main/log-latest.txt" "$temp_dir/version"
        version=$(cat "$temp_dir/version")
    fi
    version=${version#log-v}
    version=${version#v}
    printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || fail 'Invalid CODAG_LOG_VERSION; use log-v0.1.0'
    asset="codag-log-mcp_${version}_${os}_${arch}.tar.gz"
    base="https://github.com/$release_repo/releases/download/log-v$version"
    printf 'Installing Codag log MCP %s (%s/%s)...\n' "$version" "$os" "$arch"
    download "$base/$asset" "$temp_dir/$asset"
    download "$base/checksums.txt" "$temp_dir/checksums.txt"
    expected=$(awk -v name="$asset" '$2 == name {print $1}' "$temp_dir/checksums.txt")
    printf '%s\n' "$expected" | grep -Eq '^[0-9a-f]{64}$' || fail "Missing or ambiguous SHA-256 for $asset"
    if [ "$checksum_tool" = sha256sum ]; then
        actual=$(sha256sum "$temp_dir/$asset" | awk '{print $1}')
    else
        actual=$(shasum -a 256 "$temp_dir/$asset" | awk '{print $1}')
    fi
    [ "$actual" = "$expected" ] || fail 'Checksum mismatch; existing installation was left unchanged'
    if [ "${CODAG_REQUIRE_ATTESTATION:-0}" = 1 ]; then
        command -v gh >/dev/null 2>&1 || fail 'Install GitHub CLI to require build attestations'
        gh attestation verify "$temp_dir/$asset" --repo "$release_repo" || fail 'Build attestation verification failed'
    fi
    [ "$(tar -tzf "$temp_dir/$asset")" = codag-log-mcp ] || fail 'Unexpected archive contents'
    tar -xzf "$temp_dir/$asset" -C "$temp_dir"
    [ -f "$temp_dir/codag-log-mcp" ] && [ ! -L "$temp_dir/codag-log-mcp" ] || fail 'Invalid binary archive'
    chmod 755 "$temp_dir/codag-log-mcp"
    "$temp_dir/codag-log-mcp" --version || fail 'This binary cannot run on your machine; existing installation was left unchanged'
    mkdir -p "$install_dir"
    install_dir=$(CDPATH= cd -- "$install_dir" && pwd)
    install_temp=$(mktemp "$install_dir/.codag-log-mcp.XXXXXX")
    cp "$temp_dir/codag-log-mcp" "$install_temp"
    chmod 755 "$install_temp"
    mv -f "$install_temp" "$install_dir/codag-log-mcp"
    install_temp=
    printf 'Installed %s/codag-log-mcp\n' "$install_dir"
    case ":${PATH:-}:" in
        *":$install_dir:"*) ;;
        *) printf 'Add this directory to your shell PATH: %s\n' "$install_dir" ;;
    esac
    printf 'Connect your logs and agent with: %s/codag-log-mcp setup\n' "$install_dir"
    printf 'Your agent handles model access; Codag needs no separate API key.\n'
    # The script itself arrives on stdin. Read prompts from the terminal instead.
    if [ "$skip_setup" != 1 ] && ( : </dev/tty ) 2>/dev/null; then
        "$install_dir/codag-log-mcp" setup </dev/tty
    fi
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
download() { curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 --max-time 180 "$1" -o "$2" || fail "Download failed: $1"; }

# Parse the complete script before the wizard can read terminal input.
main "$@"
