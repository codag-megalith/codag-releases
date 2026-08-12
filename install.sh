#!/bin/sh

set -eu

GITHUB_REPO="codag-megalith/codag-releases"
BINARY="codag"

INSTALL_DIR="${CODAG_INSTALL_DIR:-}"
if [ -z "$INSTALL_DIR" ]; then
    if [ -z "${HOME:-}" ]; then
        printf 'Error: HOME is not set. Set CODAG_INSTALL_DIR to choose an install directory.\n' >&2
        exit 1
    fi
    INSTALL_DIR="${HOME}/.local/bin"
fi

if [ -t 1 ]; then
    RED="$(printf '\033[0;31m')"
    GREEN="$(printf '\033[0;32m')"
    YELLOW="$(printf '\033[0;33m')"
    BLUE="$(printf '\033[0;34m')"
    BOLD="$(printf '\033[1m')"
    NC="$(printf '\033[0m')"
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    BOLD=""
    NC=""
fi

info() {
    printf '%b%s%b\n' "${BLUE}==>${NC} ${BOLD}" "$1" "${NC}"
}

success() {
    printf '%b%s%b\n' "${GREEN}==>${NC} ${BOLD}" "$1" "${NC}"
}

warn() {
    printf '%b %s\n' "${YELLOW}Warning:${NC}" "$1"
}

error() {
    printf '%b %s\n' "${RED}Error:${NC}" "$1" >&2
    exit 1
}

detect_os() {
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$os" in
        darwin) echo "darwin" ;;
        linux) echo "linux" ;;
        *) error "Unsupported operating system: $os" ;;
    esac
}

detect_arch() {
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        arm64|aarch64) echo "arm64" ;;
        *) error "Unsupported architecture: $arch" ;;
    esac
}

github_api() {
    url="$1"
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$url"
    else
        curl -fsSL "$url"
    fi
}

get_latest_version() {
    url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    version="$(github_api "$url" 2>/dev/null | grep '"tag_name"' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/')"

    if [ -z "$version" ]; then
        error "Failed to fetch latest version from GitHub. Please check your internet connection."
    fi

    echo "$version"
}

resolve_version() {
    requested="${CODAG_VERSION:-}"
    if [ -z "$requested" ]; then
        get_latest_version
        return
    fi
    requested="${requested#v}"
    if ! printf '%s' "$requested" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
        error "CODAG_VERSION must be a stable semantic version such as 0.2.2."
    fi
    echo "$requested"
}

download_file() {
    url="$1"
    output="$2"

    if ! curl -fsSL "$url" -o "$output"; then
        error "Failed to download: ${url}"
    fi
}

verify_checksum() {
    file="$1"
    expected="$2"

    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$file" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    else
        error "A checksum tool (sha256sum or shasum) is required."
    fi

    if [ "$actual" != "$expected" ]; then
        error "Checksum verification failed!
  Expected: ${expected}
  Actual:   ${actual}"
    fi
}

verify_attestation() {
    file="$1"
    if ! command -v gh >/dev/null 2>&1; then
        if [ "${CODAG_REQUIRE_ATTESTATION:-0}" = "1" ]; then
            error "GitHub CLI is required because CODAG_REQUIRE_ATTESTATION=1. Install gh, then retry."
        fi
        return 1
    fi
    if ! gh attestation verify "$file" --repo "$GITHUB_REPO" >/dev/null; then
        error "Signed build-provenance verification failed for $(basename "$file")."
    fi
}

extract_archive() {
    archive_path="$1"
    tmp_dir="$2"
    tar -xzf "$archive_path" -C "$tmp_dir"
}

service_installed() {
    case "$1" in
        darwin)
            [ -n "${HOME:-}" ] && [ -f "${HOME}/Library/LaunchAgents/ai.codag.service.plist" ]
            ;;
        linux)
            [ -n "${HOME:-}" ] && [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/codag.service" ]
            ;;
        *) return 1 ;;
    esac
}

restart_service() {
    case "$1" in
        darwin) launchctl kickstart -k "gui/$(id -u)/ai.codag.service" >/dev/null 2>&1 ;;
        linux) systemctl --user restart codag.service >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

wait_for_service() {
    binary_path="$1"
    attempt=0
    while [ "$attempt" -lt 32 ]; do
        if "$binary_path" status >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.25
    done
    return 1
}

install_bash_completion() {
    binary_path="$1"
    if [ -z "${HOME:-}" ]; then
        return 0
    fi
    completion_dir="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
    completion_file="${completion_dir}/${BINARY}"

    if ! "$binary_path" completion bash >/dev/null 2>&1; then
        warn "Bash completion generator is not available in this binary."
        return 0
    fi

    if mkdir -p "$completion_dir" 2>/dev/null &&
       "$binary_path" completion bash > "$completion_file" 2>/dev/null; then
        success "Bash completion installed to ${completion_file}"
        printf '  Restart bash, or run: %bsource %s%b\n' "$BOLD" "$completion_file" "$NC"
    else
        warn "Could not install bash completion. To enable it manually, run:"
        printf '  %b%s completion bash > %s%b\n' "$BOLD" "$binary_path" "$completion_file" "$NC"
        printf '  %bsource %s%b\n' "$BOLD" "$completion_file" "$NC"
    fi
}

escape_double_quoted() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'
}

shell_startup_target() {
    if [ -z "${HOME:-}" ]; then
        return 1
    fi

    shell_name="$(basename "${SHELL:-sh}")"
    case "$shell_name" in
        zsh)
            printf '%s|sh\n' "$HOME/.zshrc"
            ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                printf '%s|sh\n' "$HOME/.bash_profile"
            else
                printf '%s|sh\n' "$HOME/.bashrc"
            fi
            ;;
        fish)
            printf '%s|fish\n' "$HOME/.config/fish/config.fish"
            ;;
        *)
            printf '%s|sh\n' "$HOME/.profile"
            ;;
    esac
}

ensure_install_dir_on_path() {
    install_dir="$1"

    target="$(shell_startup_target || true)"
    if [ -z "$target" ]; then
        warn "Could not determine a shell startup file. Add ${install_dir} to PATH manually."
        return 1
    fi
    profile="${target%%|*}"
    syntax="${target##*|}"
    escaped_dir="$(escape_double_quoted "$install_dir")"
    tmp_profile="${profile}.codag.tmp.$$"

    if ! mkdir -p "$(dirname "$profile")" 2>/dev/null; then
        warn "Could not create $(dirname "$profile"). Add ${install_dir} to PATH manually."
        return 1
    fi

    if [ -f "$profile" ]; then
        awk '
            $0 == "# >>> codag PATH >>>" { skip = 1; next }
            $0 == "# <<< codag PATH <<<" { skip = 0; next }
            skip != 1 { print }
        ' "$profile" > "$tmp_profile" || {
            rm -f "$tmp_profile"
            warn "Could not update ${profile}. Add ${install_dir} to PATH manually."
            return 1
        }
    else
        : > "$tmp_profile"
    fi

    if [ -s "$tmp_profile" ]; then
        printf '\n' >> "$tmp_profile"
    fi
    printf '# >>> codag PATH >>>\n' >> "$tmp_profile"
    if [ "$syntax" = "fish" ]; then
        printf 'fish_add_path -g "%s"\n' "$escaped_dir" >> "$tmp_profile"
    else
        printf 'export PATH="%s:$PATH"\n' "$escaped_dir" >> "$tmp_profile"
    fi
    printf '# <<< codag PATH <<<\n' >> "$tmp_profile"

    if mv "$tmp_profile" "$profile"; then
        success "Added ${install_dir} to PATH in ${profile}"
        if [ "$syntax" = "fish" ]; then
            printf '  Restart your shell after setup, or run: %bfish_add_path -g "%s"%b\n' "$BOLD" "$install_dir" "$NC"
        else
            printf '  Restart your shell after setup, or run: %bexport PATH="%s:$PATH"%b\n' "$BOLD" "$install_dir" "$NC"
        fi
        return 0
    fi

    rm -f "$tmp_profile"
    warn "Could not update ${profile}. Add ${install_dir} to PATH manually."
    return 1
}

main() {
    if ! command -v curl >/dev/null 2>&1; then
        error "curl is required but not installed. Please install curl and try again."
    fi

    info "Installing Codag CLI..."

    os="$(detect_os)"
    arch="$(detect_arch)"
    info "Detected platform: ${os}/${arch}"

    if [ -n "${CODAG_VERSION:-}" ]; then
        info "Using requested version..."
    else
        info "Fetching latest version..."
    fi
    version="$(resolve_version)"
    version="${version#v}"
    info "Installing version: ${version}"

    binary_file="${BINARY}"
    archive_name="codag_${os}_${arch}.tar.gz"
    download_url="https://github.com/${GITHUB_REPO}/releases/download/v${version}/${archive_name}"
    checksums_url="https://github.com/${GITHUB_REPO}/releases/download/v${version}/checksums.txt"

    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' 0

    info "Downloading ${archive_name}..."
    archive_path="${tmp_dir}/${archive_name}"
    download_file "$download_url" "$archive_path"

    info "Verifying checksum..."
    checksums_path="${tmp_dir}/checksums.txt"
    download_file "$checksums_url" "$checksums_path"

    expected_checksum="$(awk -v name="$archive_name" 'tolower($2) == tolower(name) { print $1; exit }' "$checksums_path")"
    if [ -z "$expected_checksum" ]; then
        error "Checksum for ${archive_name} not found in checksums.txt"
    fi
    verify_checksum "$archive_path" "$expected_checksum"
    success "Checksum verified"

    if command -v gh >/dev/null 2>&1; then
        info "Verifying signed build provenance..."
        verify_attestation "$archive_path"
        success "Signed provenance verified"
    elif [ "${CODAG_REQUIRE_ATTESTATION:-0}" = "1" ]; then
        verify_attestation "$archive_path"
    else
        info "GitHub CLI not found; continuing with mandatory checksum verification."
    fi

    info "Extracting..."
    extract_archive "$archive_path" "$tmp_dir"

    binary_path="${tmp_dir}/${binary_file}"
    if [ ! -f "$binary_path" ]; then
        error "Archive did not contain ${binary_file}"
    fi
    chmod +x "$binary_path" 2>/dev/null || true

    info "Installing to ${INSTALL_DIR}..."
    mkdir -p "$INSTALL_DIR"

    if [ ! -w "$INSTALL_DIR" ]; then
        error "Cannot write to ${INSTALL_DIR}. Please check permissions."
    fi

    installed_binary="${INSTALL_DIR}/${binary_file}"
    staged_binary="${INSTALL_DIR}/.${binary_file}.new.$$"
    rollback_binary="${INSTALL_DIR}/.${binary_file}.rollback"
    service_active=0
    if service_installed "$os"; then
        service_active=1
    fi
    mv "$binary_path" "$staged_binary"
    chmod +x "$staged_binary"
    if ! "$staged_binary" version >/dev/null 2>&1; then
        error "The verified binary failed its pre-install health check."
    fi
    if [ -f "$installed_binary" ]; then
        mv "$installed_binary" "$rollback_binary"
    fi
    if ! mv "$staged_binary" "$installed_binary"; then
        if [ -f "$rollback_binary" ]; then
            mv "$rollback_binary" "$installed_binary"
        fi
        error "Atomic installation failed; the previous binary was restored."
    fi
    if ! "$installed_binary" version >/dev/null 2>&1; then
        rm -f "$installed_binary"
        if [ -f "$rollback_binary" ]; then
            mv "$rollback_binary" "$installed_binary"
        fi
        error "Post-install health check failed; the previous binary was restored."
    fi
    if [ "$service_active" -eq 1 ]; then
        info "Restarting the Codag service..."
        if ! restart_service "$os" || ! wait_for_service "$installed_binary"; then
            rm -f "$installed_binary"
            if [ -f "$rollback_binary" ]; then
                mv "$rollback_binary" "$installed_binary"
                restart_service "$os" >/dev/null 2>&1 || true
                error "Updated service failed its health check; the previous binary was restored."
            fi
            error "Updated service failed its health check and no previous binary was available."
        fi
        success "Codag service restarted and healthy"
    fi
    rm -f "$rollback_binary"
    success "Codag CLI v${version} installed to ${installed_binary}"

    install_bash_completion "$installed_binary"

    path_binary="$(command -v "$BINARY" 2>/dev/null || command -v "$binary_file" 2>/dev/null || true)"

    if [ -n "$path_binary" ] && [ "$path_binary" != "$installed_binary" ]; then
        printf '\n'
        printf '  %bWARNING: PATH conflict detected%b\n\n' "$YELLOW" "$NC"
        printf '  Installed to: %s\n' "$installed_binary"
        printf '  But %s resolves to: %s\n\n' "$BINARY" "$path_binary"
        ensure_install_dir_on_path "$INSTALL_DIR" || true
        printf '\n'
    elif [ -z "$path_binary" ]; then
        printf '\n'
        ensure_install_dir_on_path "$INSTALL_DIR" || true
        printf '\n'
    fi

    run_binary="$BINARY"
    if [ "$path_binary" != "$installed_binary" ]; then
        run_binary="$installed_binary"
    fi
    printf '  Set up Codag once, then keep using Claude Code or Codex normally:\n\n'
    printf '    %b%s setup%b\n' "$BOLD" "$run_binary" "$NC"
    printf '    %bor use CODAG_API_KEY=cdk_... for noninteractive setup%b\n' "$BOLD" "$NC"
    printf '\n'
}

main "$@"
