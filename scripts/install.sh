#!/usr/bin/env bash
# Comobot One-Click Installer for macOS / Linux
# Usage: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/musenming/comobot-install/main/scripts/install.sh)"
set -euo pipefail

REPO="musenming/comobot"
INSTALL_DIR_LINUX="$HOME/.local/comobot"
INSTALL_DIR_MAC="$HOME/Applications/comobot"
DATA_DIR="$HOME/.comobot"
PORT=18790

# Global variables set by functions
OS=""
INSTALL_DIR=""
PYTHON=""
TMP_ZIP=""

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[comobot]${NC} $*" >&2; }
success() { echo -e "${GREEN}[comobot]${NC} $*" >&2; }
warn()    { echo -e "${YELLOW}[comobot]${NC} $*" >&2; }
error()   { echo -e "${RED}[comobot]${NC} $*" >&2; exit 1; }

# ── OS detection ──────────────────────────────────────────────────────────────
detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
    INSTALL_DIR="$INSTALL_DIR_MAC"
    local macos_ver
    macos_ver=$(sw_vers -productVersion | cut -d. -f1)
    [[ "$macos_ver" -ge 12 ]] || error "Comobot requires macOS 12 (Monterey) or later. Current: $(sw_vers -productVersion)"
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
    INSTALL_DIR="$INSTALL_DIR_LINUX"
  else
    error "Unsupported OS: $OSTYPE. Comobot supports macOS 12+ and Linux."
  fi
  info "Detected OS: $OS"
}

# ── Homebrew (macOS) ──────────────────────────────────────────────────────────
ensure_homebrew() {
  if ! command -v brew &>/dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
  fi
  # Update brew to ensure latest formula list
  info "Updating Homebrew (this may take a moment)..."
  if ! brew update 2>&1 | tail -3 >&2; then
    warn "brew update had issues, continuing..."
  fi
  success "Homebrew ready"
}

# ── Install Python from python.org (macOS fallback) ──────────────────────────
install_python_from_official() {
  # Python.org provides universal2 pkg installers for macOS 10.9+
  # These work on ALL macOS 12-15, Intel and Apple Silicon, no brew needed
  local py_version="3.12.10"
  local pkg_name="python-${py_version}-macos11.pkg"

  # Try China mirror first (Huawei), fallback to python.org
  local urls=(
    "https://repo.huaweicloud.com/python/${py_version}/${pkg_name}"
    "https://registry.npmmirror.com/-/binary/python/${py_version}/${pkg_name}"
    "https://www.python.org/ftp/python/${py_version}/${pkg_name}"
  )

  local tmp_pkg
  tmp_pkg=$(mktemp -d)/python.pkg
  local downloaded=false

  for url in "${urls[@]}"; do
    info "Downloading Python ${py_version} from ${url%%/${pkg_name}} ..."
    if curl -fsSL --connect-timeout 10 "$url" -o "$tmp_pkg" 2>/dev/null; then
      downloaded=true
      break
    fi
    warn "Download failed, trying next mirror..."
  done

  if ! $downloaded; then
    rm -f "$tmp_pkg"
    return 1
  fi

  info "Installing Python ${py_version} (may require password)..."
  if ! sudo installer -pkg "$tmp_pkg" -target / < /dev/tty 2>/dev/null; then
    rm -f "$tmp_pkg"
    return 1
  fi
  rm -f "$tmp_pkg"

  # python.org installs to /Library/Frameworks/Python.framework/Versions/3.12/bin
  local fw_python="/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12"
  if [[ -x "$fw_python" ]]; then
    PYTHON="$fw_python"
    return 0
  fi

  # Also check if it landed in PATH
  if command -v python3.12 &>/dev/null; then
    PYTHON="python3.12"
    return 0
  fi

  return 1
}

# ── Python 3.11+ ─────────────────────────────────────────────────────────────
ensure_python() {
  PYTHON=""
  # Search for existing Python 3.11+ (newest first)
  for cmd in python3.13 python3.12 python3.11 python3; do
    if command -v "$cmd" &>/dev/null; then
      local py_major py_minor
      py_major=$("$cmd" -c "import sys; print(sys.version_info[0])") || continue
      py_minor=$("$cmd" -c "import sys; print(sys.version_info[1])") || continue
      if [[ "$py_major" -ge 3 && "$py_minor" -ge 11 ]]; then
        PYTHON="$cmd"
        break
      fi
    fi
  done

  if [[ -n "$PYTHON" ]]; then
    success "Python: $($PYTHON --version)"
    return
  fi

  info "No Python 3.11+ found, installing..."

  if [[ "$OS" == "macos" ]]; then
    # Strategy 1: try Homebrew
    local installed=false
    if command -v brew &>/dev/null; then
      for pyver in python@3.13 python@3.12 python@3.11; do
        info "Trying: brew install $pyver ..."
        if brew install "$pyver" 2>&1 >&2; then
          local py_bin
          py_bin="$(brew --prefix "$pyver" 2>/dev/null)/bin/python3"
          if [[ -x "$py_bin" ]] && "$py_bin" --version &>/dev/null; then
            PYTHON="$py_bin"
            installed=true
            break
          fi
        fi
        warn "$pyver not available via brew, trying next..."
      done
    fi

    # Strategy 2: python.org official installer (works on ALL macOS)
    if ! $installed; then
      warn "Homebrew cannot install Python, trying python.org installer..."
      if install_python_from_official; then
        installed=true
      fi
    fi

    if ! $installed; then
      error "Cannot install Python 3.11+. Please install from https://www.python.org/downloads/ and re-run."
    fi

  elif command -v apt-get &>/dev/null; then
    local installed=false
    for pyver in 3.13 3.12 3.11; do
      if sudo apt-get update -qq && sudo apt-get install -y "python${pyver}" "python${pyver}-venv" python3-pip 2>/dev/null; then
        PYTHON="python${pyver}"
        installed=true
        break
      fi
    done
    if ! $installed; then
      error "Cannot install Python 3.11+. Please install manually and re-run."
    fi

  elif command -v yum &>/dev/null; then
    local installed=false
    for pyver in 3.13 3.12 3.11; do
      if sudo yum install -y "python${pyver}" 2>/dev/null; then
        PYTHON="python${pyver}"
        installed=true
        break
      fi
    done
    if ! $installed; then
      error "Cannot install Python 3.11+. Please install manually and re-run."
    fi

  else
    error "Cannot auto-install Python. Please install Python 3.11+ and re-run."
  fi

  # Final verification
  if ! "$PYTHON" --version &>/dev/null; then
    error "Python installation failed. Please install Python 3.11+ manually."
  fi
  success "Python: $($PYTHON --version)"
}

# ── Node.js 18+ ───────────────────────────────────────────────────────────────
ensure_node() {
  if command -v node &>/dev/null; then
    local node_major
    node_major=$(node -e "console.log(parseInt(process.version.slice(1)))")
    if [[ "$node_major" -ge 18 ]]; then
      success "Node.js: $(node --version)"
      return
    fi
  fi
  info "Installing Node.js..."
  if [[ "$OS" == "macos" ]]; then
    brew install node
  elif command -v apt-get &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
  elif command -v yum &>/dev/null; then
    curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
    sudo yum install -y nodejs
  else
    error "Cannot auto-install Node.js. Please install Node.js 18+ and re-run."
  fi
  success "Node.js: $(node --version)"
}

# ── Download latest release ───────────────────────────────────────────────────
download_release() {
  info "Fetching latest release from GitHub..."

  local latest_url=""
  local curl_opts=(-fsSL)
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_opts+=(-H "Authorization: token $GITHUB_TOKEN")
  fi

  latest_url=$(curl "${curl_opts[@]}" "https://api.github.com/repos/$REPO/releases/latest" \
    2>/dev/null | grep '"zipball_url"' | cut -d'"' -f4) || true

  if [[ -z "$latest_url" ]]; then
    latest_url="https://github.com/$REPO/archive/refs/heads/main.zip"
    warn "No release found, using main branch"
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)
  TMP_ZIP="$tmp_dir/comobot.zip"

  info "Downloading $latest_url ..."
  curl -fsSL -L "$latest_url" -o "$TMP_ZIP" \
    || error "Download failed. Check your network connection."
}

# ── Extract & setup ───────────────────────────────────────────────────────────
install_comobot() {
  info "Installing to $INSTALL_DIR ..."
  mkdir -p "$INSTALL_DIR"

  local tmp_dir
  tmp_dir=$(mktemp -d)
  unzip -q "$TMP_ZIP" -d "$tmp_dir"

  # Move extracted contents (GitHub adds a prefix dir)
  local extracted
  extracted=$(ls "$tmp_dir" | head -1)
  cp -r "$tmp_dir/$extracted/." "$INSTALL_DIR/"
  rm -rf "$tmp_dir" "$TMP_ZIP"

  # Create venv
  info "Creating Python virtual environment..."
  "$PYTHON" -m venv "$INSTALL_DIR/.venv"
  "$INSTALL_DIR/.venv/bin/pip" install --upgrade pip setuptools wheel -q
  "$INSTALL_DIR/.venv/bin/pip" install -e "$INSTALL_DIR" -q
  success "Python dependencies installed"

  # Build frontend
  if [[ -d "$INSTALL_DIR/web" ]]; then
    info "Building frontend..."
    (cd "$INSTALL_DIR/web" && npm ci --silent && npm run build --silent)
    success "Frontend built"
  fi

  # Create data directory
  mkdir -p "$DATA_DIR/workspace"
  success "Data directory: $DATA_DIR"
}

# ── macOS LaunchAgent (autostart) ─────────────────────────────────────────────
setup_macos_autostart() {
  local plist_dir="$HOME/Library/LaunchAgents"
  local plist="$plist_dir/ai.comobot.gateway.plist"
  mkdir -p "$plist_dir"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.comobot.gateway</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_DIR/.venv/bin/comobot</string>
    <string>gateway</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$DATA_DIR/gateway.log</string>
  <key>StandardErrorPath</key>
  <string>$DATA_DIR/gateway-error.log</string>
</dict>
</plist>
EOF
  launchctl load "$plist" 2>/dev/null || true
  success "macOS autostart configured"
}

# ── Linux systemd (optional) ──────────────────────────────────────────────────
setup_linux_autostart() {
  if ! command -v systemctl &>/dev/null; then return; fi
  local service="$HOME/.config/systemd/user/comobot.service"
  mkdir -p "$(dirname "$service")"
  cat > "$service" <<EOF
[Unit]
Description=Comobot Gateway
After=network.target

[Service]
ExecStart=$INSTALL_DIR/.venv/bin/comobot gateway
Restart=always
RestartSec=5
StandardOutput=append:$DATA_DIR/gateway.log
StandardError=append:$DATA_DIR/gateway-error.log

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now comobot 2>/dev/null || true
  success "Linux systemd service enabled"
}

# ── Desktop shortcut ──────────────────────────────────────────────────────────
create_shortcut() {
  if [[ "$OS" == "macos" ]]; then
    local shortcut="$HOME/Desktop/Comobot.command"
    cat > "$shortcut" <<EOF
#!/bin/bash
open http://localhost:$PORT
EOF
    chmod +x "$shortcut"
    success "Desktop shortcut: $shortcut"
  fi
}

# ── Start service ─────────────────────────────────────────────────────────────
start_service() {
  info "Starting Comobot gateway..."
  nohup "$INSTALL_DIR/.venv/bin/comobot" gateway \
    > "$DATA_DIR/gateway.log" 2>&1 &
  sleep 2
  if kill -0 $! 2>/dev/null; then
    success "Gateway started (PID $!)"
  else
    warn "Gateway may have failed to start. Check $DATA_DIR/gateway.log"
  fi
}

# ── Open browser ──────────────────────────────────────────────────────────────
open_browser() {
  local url="http://localhost:$PORT"
  info "Opening $url ..."
  sleep 1
  if [[ "$OS" == "macos" ]]; then
    open "$url"
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$url"
  else
    info "Please open $url in your browser"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "  ╔═══════════════════════════════╗"
  echo "  ║   Comobot Installer v1.0      ║"
  echo "  ╚═══════════════════════════════╝"
  echo ""

  detect_os

  if [[ "$OS" == "macos" ]]; then
    ensure_homebrew
  fi

  ensure_python
  ensure_node

  download_release
  install_comobot

  if [[ "$OS" == "macos" ]]; then
    setup_macos_autostart
  elif [[ "$OS" == "linux" ]]; then
    setup_linux_autostart
  fi

  create_shortcut
  start_service
  open_browser

  echo "" >&2
  success "Installation complete!"
  echo -e "  ${GREEN}→${NC} Open http://localhost:$PORT to configure Comobot" >&2
  echo -e "  ${GREEN}→${NC} Data stored in $DATA_DIR" >&2
  echo "" >&2
}

main "$@"
