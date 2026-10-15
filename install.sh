#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Dotfiles installer -- Fedora
#
# Targets Fedora Minimal: the base system from packages/fedora-base.txt,
# then Umbriel, Noctalia and everyday tools on top of it.
#
# On Fedora Workstation the result is the same, plus GNOME, which stays
# installed as a fallback in case Umbriel breaks; unused GNOME apps are
# removed first (packages/fedora-remove.txt).
#
# Runs in two stages ONLY when needed: an NVIDIA machine with Secure
# Boot enabled has to reboot to enroll the MOK key before the kernel
# module can load. Otherwise it runs to completion in one go.
# ==========================================

REPO="https://github.com/r3p-dev/dotfiles/archive/refs/heads/main.tar.gz"
STATE_FILE="$HOME/.local/state/r3p-dotfiles-stage"
MOK_KEY="/etc/pki/akmods/certs/public_key.der"

TEMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

MISSING_PACKAGES=()

echo "==> Dotfiles installer"
echo

# ------------------------------------------
# Make sure this is Fedora
# ------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: /etc/os-release not found."
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

if [[ "$ID" != "fedora" ]]; then
    echo "ERROR: This script targets Fedora. Detected: $ID"
    exit 1
fi

echo "==> $PRETTY_NAME"

if ! command -v sudo &>/dev/null; then
    echo "ERROR: sudo is not installed."
    exit 1
fi

# ------------------------------------------
# Sudo
# ------------------------------------------
#
# Ask for the password now, while someone is still at the screen. If
# the prompt shows up in the middle of package installation, it is easy
# to miss and sudo times out.

echo "==> Requesting sudo access..."

if ! sudo -v; then
    echo "ERROR: sudo authentication failed."
    exit 1
fi

while true; do
    sudo -n true
    sleep 50
    kill -0 "$$" 2>/dev/null || exit
done &>/dev/null &

SUDO_KEEPALIVE_PID=$!

cleanup_sudo() {
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
}

trap 'cleanup; cleanup_sudo' EXIT

# ------------------------------------------
# Bootstrap tools
# ------------------------------------------
#
# Minimal Install (@core) ships without tar, git or pciutils, and all
# three are needed before anything else -- including lspci to detect
# NVIDIA.

BOOTSTRAP_TOOLS=()

for tool in curl tar git lspci; do
    command -v "$tool" &>/dev/null || BOOTSTRAP_TOOLS+=("$tool")
done

if ((${#BOOTSTRAP_TOOLS[@]} > 0)); then
    echo "==> Installing bootstrap tools: ${BOOTSTRAP_TOOLS[*]}"

    # lspci lives in the package named pciutils.
    sudo dnf install -y "${BOOTSTRAP_TOOLS[@]/lspci/pciutils}"
fi

# ------------------------------------------
# Hardware detection
# ------------------------------------------

HAS_NVIDIA=0

if lspci | grep -qi 'vga\|3d controller' && lspci | grep -qi nvidia; then
    HAS_NVIDIA=1
    echo "==> NVIDIA GPU detected"
else
    echo "==> No NVIDIA GPU; skipping proprietary driver"
fi

SECURE_BOOT=0

if command -v mokutil &>/dev/null; then
    if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
        SECURE_BOOT=1
    fi
elif [[ -d /sys/firmware/efi ]]; then
    # mokutil is not installed yet; read the EFI variable directly. The
    # last byte of SecureBoot is 1 when it is enabled.
    if [[ -r /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c ]]; then
        if [[ "$(od -An -t u1 -j 4 -N 1 \
            /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c |
            tr -d ' ')" == "1" ]]; then
            SECURE_BOOT=1
        fi
    fi
fi

((SECURE_BOOT)) && echo "==> Secure Boot is enabled"

# ------------------------------------------
# Stage detection
# ------------------------------------------

STAGE=1

[[ -f "$STATE_FILE" ]] && STAGE="$(cat "$STATE_FILE")"

# ==========================================
# STAGE 1 -- MOK key enrollment
# ==========================================
#
# Only relevant for NVIDIA with Secure Boot. Modules built by akmods
# are signed with a local key, and that key has to be enrolled in the
# firmware before the kernel will load them. Enrollment needs a reboot
# and a manual confirmation on the blue MOK Manager screen.

if ((STAGE == 1)) && ((HAS_NVIDIA)) && ((SECURE_BOOT)); then
    echo
    echo "=========================================="
    echo " Stage 1: Secure Boot key enrollment"
    echo "=========================================="

    sudo dnf install -y kmodtool akmods mokutil openssl

    if sudo mokutil --test-key "$MOK_KEY" 2>/dev/null | grep -qi 'already enrolled'; then
        echo "==> MOK key is already enrolled; skipping to stage 2"
        STAGE=2
    else
        echo "==> Generating akmods signing key"
        sudo kmodgenca -a

        echo "==> Importing MOK key"
        echo "==> You will be asked for a one-time password."
        echo "==> Remember it: the blue MOK Manager screen asks for it after reboot."

        sudo mokutil --import "$MOK_KEY"

        mkdir -p "$(dirname "$STATE_FILE")"
        echo "2" >"$STATE_FILE"

        echo
        echo "=========================================="
        echo " REBOOT REQUIRED"
        echo "=========================================="
        echo "1. Reboot now"
        echo "2. On the blue MOK Manager screen: Enroll MOK -> Continue"
        echo "3. Enter the password you just set"
        echo "4. Boot back into Fedora and run this script again"
        echo

        read -rp "Press ENTER to reboot, or Ctrl-C to reboot later..."
        sudo reboot
        exit 0
    fi
fi

# ==========================================
# STAGE 2 -- full installation
# ==========================================

echo "==> Downloading dotfiles..."

curl -fsSL "$REPO" | tar -xz -C "$TEMP_DIR"

SCRIPT_DIR="$TEMP_DIR/dotfiles-main"

FEDORA_BASE_PACKAGES="$SCRIPT_DIR/packages/fedora-base.txt"
FEDORA_PACKAGES="$SCRIPT_DIR/packages/fedora.txt"
FEDORA_REMOVE_PACKAGES="$SCRIPT_DIR/packages/fedora-remove.txt"
CARGO_PACKAGES="$SCRIPT_DIR/packages/cargo.txt"
CONFIGS_DIR="$SCRIPT_DIR/configs"

read_package_list() {
    local file="$1"

    [[ -f "$file" ]] || return 1

    grep -vE '^[[:space:]]*(#|$)' "$file" | sed 's/[[:space:]]*#.*$//'
}

dnf_install() {
    # Try everything in one go first. If a single package name is
    # unavailable, dnf aborts the whole transaction, so the fallback
    # installs them one by one and records the ones that fail.

    if sudo dnf install -y "$@"; then
        return 0
    fi

    echo "==> Falling back to per-package installation..."

    local pkg

    for pkg in "$@"; do
        if ! sudo dnf install -y "$pkg"; then
            MISSING_PACKAGES+=("$pkg")
        fi
    done
}

add_repo_file() {
    local url="$1"

    sudo dnf config-manager addrepo --from-repofile="$url" 2>/dev/null 
}

# ------------------------------------------
# Unused preinstalled apps
# ------------------------------------------
#
# Only matters on Workstation; on Minimal nothing matches. Removed
# before the upgrade so they are not downloaded. The list may contain
# patterns (libreoffice*); names that are not installed are skipped,
# because dnf fails the whole transaction if a single name is missing.

if [[ -f "$FEDORA_REMOVE_PACKAGES" ]]; then
    echo "==> Removing unused Workstation apps..."

    mapfile -t REMOVE_PATTERNS < <(read_package_list "$FEDORA_REMOVE_PACKAGES")
    mapfile -t INSTALLED < <(rpm -qa --qf '%{NAME}\n')

    TO_REMOVE=()

    for pattern in "${REMOVE_PATTERNS[@]}"; do
        for name in "${INSTALLED[@]}"; do
            # $pattern is unquoted so it is matched as a glob.
            # shellcheck disable=SC2053
            if [[ "$name" == $pattern ]]; then
                TO_REMOVE+=("$name")
            fi
        done
    done

    if ((${#TO_REMOVE[@]} > 0)); then
        sudo dnf remove -y "${TO_REMOVE[@]}" ||
            echo "WARNING: some apps could not be removed."
        sudo dnf autoremove -y || true
    else
        echo "    -> Nothing to remove."
    fi
fi

echo "==> Updating system..."
sudo dnf upgrade -y --refresh

# ------------------------------------------
# RPM Fusion
# ------------------------------------------

echo "==> Enabling RPM Fusion..."

sudo dnf install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$VERSION_ID.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$VERSION_ID.noarch.rpm" ||
    echo "WARNING: RPM Fusion setup failed; codecs and NVIDIA driver will be unavailable."

# ------------------------------------------
# Codec
# ------------------------------------------
#
# Fedora ships a trimmed ffmpeg-free (no H.264/H.265/AAC). The full
# package from RPM Fusion conflicts with it, so it has to be 'swap',
# not 'install' -- that is why ffmpeg is not in fedora.txt.

echo "==> Swapping to full ffmpeg..."

sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing ||
    echo "WARNING: ffmpeg swap failed or was already done."

echo "==> Installing multimedia groups..."

sudo dnf group upgrade -y multimedia \
    --setopt="install_weak_deps=False" \
    --exclude=PackageKit-gstreamer-plugin ||
    echo "WARNING: multimedia group upgrade failed."

sudo dnf group upgrade -y sound-and-video ||
    echo "WARNING: sound-and-video group upgrade failed."

# Same as ffmpeg: Fedora's Mesa VA-API drivers are trimmed, and the full
# version from RPM Fusion conflicts -- so swap, not install. AMD iGPUs
# use these for hardware-accelerated video decoding.

echo "==> Swapping to full Mesa VA-API drivers..."

sudo dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld --allowerasing ||
    echo "WARNING: mesa-va-drivers swap failed or was already done."

# ------------------------------------------
# Terra
# ------------------------------------------

echo "==> Enabling Terra..."

sudo dnf install -y --nogpgcheck \
    --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
    terra-release ||
    echo "WARNING: Terra setup failed; umbriel and noctalia-greeter will be missing."

# ------------------------------------------
# COPR
# ------------------------------------------
#
# hyprpicker and yazi are not in the official Fedora repositories.

echo "==> Enabling COPR repositories..."

# dnf5 moved the copr subcommand into a separate plugin package.
sudo dnf install -y dnf5-plugins 2>/dev/null ||
    sudo dnf install -y dnf-plugins-core ||
    echo "WARNING: dnf plugins install failed; copr may be unavailable."

sudo dnf -y copr enable lionheartp/Hyprland ||
    echo "WARNING: COPR lionheartp/Hyprland failed; hyprpicker will be missing."

sudo dnf -y copr enable lihaohong/yazi ||
    echo "WARNING: COPR lihaohong/yazi failed; yazi will be missing."

# ------------------------------------------
# Vendor repositories
# ------------------------------------------

echo "==> Adding vendor repositories..."

if [[ ! -f /etc/yum.repos.d/brave-browser.repo ]]; then
    add_repo_file https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo ||
        echo "WARNING: Brave repository setup failed."
fi

if [[ ! -f /etc/yum.repos.d/vscode.repo ]]; then
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc || true

    sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
fi

if [[ ! -f /etc/yum.repos.d/gh-cli.repo ]]; then
    add_repo_file https://cli.github.com/packages/rpm/gh-cli.repo ||
        echo "WARNING: GitHub CLI repository setup failed."
fi

if [[ ! -f /etc/yum.repos.d/cloudflared.repo ]]; then
    add_repo_file https://pkg.cloudflare.com/cloudflared.repo ||
        echo "WARNING: cloudflared repository setup failed."
fi

# ------------------------------------------
# Packages
# ------------------------------------------
#
# Base system first: audio, network, Bluetooth, fonts, and everything
# else Minimal lacks. On Workstation most of it is already installed.

if [[ -f "$FEDORA_BASE_PACKAGES" ]]; then
    echo "==> Installing base system packages..."

    mapfile -t FEDORA_BASE < <(read_package_list "$FEDORA_BASE_PACKAGES")

    if ((${#FEDORA_BASE[@]} > 0)); then
        dnf_install "${FEDORA_BASE[@]}"
    fi
fi

if [[ -f "$FEDORA_PACKAGES" ]]; then
    echo "==> Installing packages..."

    mapfile -t FEDORA < <(read_package_list "$FEDORA_PACKAGES")

    if ((${#FEDORA[@]} > 0)); then
        dnf_install "${FEDORA[@]}"
    fi
else
    echo "WARNING: $FEDORA_PACKAGES not found."
fi

# ------------------------------------------
# NVIDIA driver
# ------------------------------------------
#
# akmod builds the module against the installed kernel, in the
# background after the package is installed. Rebooting before the build
# finishes boots without a driver, so wait until the module exists.

if ((HAS_NVIDIA)); then
    echo "==> Installing NVIDIA driver..."

    # The "open" variant matches nvidia-open on Arch, and it is what
    # NVIDIA recommends for Turing and newer.

    dnf_install \
        akmod-nvidia-open \
        xorg-x11-drv-nvidia-cuda \
        libva-nvidia-driver \
        libva-utils \
        vdpauinfo

    # Mark it as user-installed so autoremove does not remove it when
    # cleaning up dependencies.
    sudo dnf mark user akmod-nvidia-open 2>/dev/null || true

    echo "==> Waiting for the kernel module to build (up to 10 minutes)..."

    NVIDIA_READY=0

    for i in {1..60}; do
        if modinfo -F version nvidia &>/dev/null; then
            NVIDIA_READY=1
            break
        fi

        echo "    -> building... ($i/60)"
        sleep 10
    done

    if ((NVIDIA_READY)); then
        echo "==> NVIDIA module ready: $(modinfo -F version nvidia)"
    else
        echo "WARNING: NVIDIA module is not ready yet."
        echo "WARNING: Watch it with: journalctl --follow --grep=akmod"
        echo "WARNING: Do not reboot until it finishes."
    fi
fi

# ------------------------------------------
# Per-user toolchains
# ------------------------------------------
#
# Node (via fnm), Bun and Rust are installed with their official
# installers into the home directory, not with dnf, so their versions
# can be changed without sudo. The installers may edit the fish config;
# config.fish and conf.d/ from this repo are copied later and overwrite it.

if [[ ! -x "$HOME/.local/share/fnm/fnm" ]]; then
    echo "==> Installing fnm..."
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell ||
        MISSING_PACKAGES+=("fnm")
fi

if [[ ! -x "$HOME/.bun/bin/bun" ]]; then
    echo "==> Installing Bun..."
    curl -fsSL https://bun.sh/install | bash ||
        MISSING_PACKAGES+=("bun")
fi

if [[ ! -x "$HOME/.cargo/bin/rustup" ]]; then
    echo "==> Installing Rust (rustup)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y ||
        MISSING_PACKAGES+=("rustup")
fi

# Crates from packages/cargo.txt. cargo is not on PATH yet when rustup
# was just installed, so call it from ~/.cargo/bin directly. cargo itself
# skips crates that are already installed at the latest version.

CARGO="$HOME/.cargo/bin/cargo"

if [[ -f "$CARGO_PACKAGES" && -x "$CARGO" ]]; then
    echo "==> Installing cargo packages..."

    mapfile -t CARGO_CRATES < <(read_package_list "$CARGO_PACKAGES")

    for crate in "${CARGO_CRATES[@]}"; do
        "$CARGO" install --locked "$crate" ||
            MISSING_PACKAGES+=("cargo:$crate")
    done
fi

# ------------------------------------------
# Greeter
# ------------------------------------------

GREETER_SESSION="$(command -v noctalia-greeter-session || true)"
REBOOT_REQUIRED=0

if [[ -n "$GREETER_SESSION" ]]; then
    echo "==> Configuring Noctalia greeter..."

    sudo install -d /etc/greetd

    # The account that runs the greeter is named differently per distro:
    # the Arch package creates "greeter", the Fedora RPM creates "greetd"
    # via sysusers.d. Wrong name -> greetd dies at once with "session
    # user not found".

    GREETER_USER=""

    for candidate in greeter greetd; do
        if getent passwd "$candidate" &>/dev/null; then
            GREETER_USER="$candidate"
            break
        fi
    done

    if [[ -z "$GREETER_USER" ]]; then
        echo "ERROR: No greeter account found (tried: greeter, greetd)."
        echo "ERROR: Is the greetd package installed?"
        exit 1
    fi

    echo "    -> Greeter account: $GREETER_USER"
    echo "    -> Writing /etc/greetd/config.toml"

    sudo tee /etc/greetd/config.toml >/dev/null <<EOF
[terminal]
vt = 1

[default_session]
command = "$GREETER_SESSION -- --session umbriel"
user = "$GREETER_USER"
EOF

    # The greeter writes its config and logs here; the wrong owner gives
    # a black screen even though the service looks active.

    if [[ -d /var/lib/noctalia-greeter ]]; then
        echo "    -> Fixing ownership of /var/lib/noctalia-greeter"
        sudo chown -R "$GREETER_USER": /var/lib/noctalia-greeter
    fi

    DM_LINK="/etc/systemd/system/display-manager.service"

    if [[ -L "$DM_LINK" ]]; then
        CURRENT_DM="$(basename "$(readlink -f "$DM_LINK")")"

        if [[ "$CURRENT_DM" != "greetd.service" ]]; then
            echo "    -> Disabling $CURRENT_DM"
            sudo systemctl disable "$CURRENT_DM"
        fi
    fi

    echo "    -> Enabling greetd"
    sudo systemctl reset-failed greetd 2>/dev/null || true
    sudo systemctl enable greetd

    # A minimal Fedora install defaults to multi-user.target, so boot
    # stops at a TTY and greetd never starts.

    if [[ "$(systemctl get-default)" != "graphical.target" ]]; then
        echo "    -> Setting default target to graphical"
        sudo systemctl set-default graphical.target
    fi

    if [[ ! -e "$DM_LINK" ]]; then
        echo "WARNING: display-manager.service alias was not created."
        echo "WARNING: Run: sudo ln -sf /usr/lib/systemd/system/greetd.service \\"
        echo "WARNING:          /etc/systemd/system/display-manager.service"
    fi

    REBOOT_REQUIRED=1
else
    echo "WARNING: noctalia-greeter-session was not found."
    echo "WARNING: Skipping greetd configuration."
fi

# ------------------------------------------
# Fish as the default shell
# ------------------------------------------

FISH_PATH="$(command -v fish || true)"

if [[ -n "$FISH_PATH" ]]; then
    CURRENT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"

    if [[ "$CURRENT_SHELL" != "$FISH_PATH" ]]; then
        echo "==> Setting Fish as default shell..."

        if ! grep -qxF "$FISH_PATH" /etc/shells; then
            echo "    -> Adding $FISH_PATH to /etc/shells"
            echo "$FISH_PATH" | sudo tee -a /etc/shells >/dev/null
        fi

        # chsh lives in util-linux-user, which Fedora does not install
        # by default.

        if command -v chsh &>/dev/null; then
            sudo chsh -s "$FISH_PATH" "$USER"
        else
            sudo usermod -s "$FISH_PATH" "$USER"
        fi

        echo "    -> Fish is now the default shell."
    else
        echo "==> Fish is already the default shell."
    fi
else
    echo "WARNING: fish was not found; cannot set default shell."
fi

# ------------------------------------------
# Wallpaper
# ------------------------------------------

WALLPAPERS_DIR="$SCRIPT_DIR/wallpapers"
WALLPAPERS_TARGET="$HOME/Pictures/Wallpapers"

if [[ -d "$WALLPAPERS_DIR" ]]; then
    echo "==> Installing wallpapers..."
    mkdir -p "$WALLPAPERS_TARGET"
    cp -a "$WALLPAPERS_DIR"/. "$WALLPAPERS_TARGET"/
fi

# ------------------------------------------
# Config
# ------------------------------------------

echo "==> Installing config files..."

mkdir -p "$HOME/.config"

if [[ -d "$CONFIGS_DIR" ]]; then
    for config in "$CONFIGS_DIR"/*; do
        [[ -e "$config" ]] || continue

        name="$(basename "$config")"

        echo "    -> $name"

        cp -a "$config" "$HOME/.config/"
    done
else
    echo "WARNING: $CONFIGS_DIR not found."
fi

# ------------------------------------------
# ~/.local (desktop entries, etc.)
# ------------------------------------------

LOCAL_DIR="$SCRIPT_DIR/locals"

if [[ -d "$LOCAL_DIR" ]]; then
    echo "==> Installing ~/.local files..."
    mkdir -p "$HOME/.local"
    cp -a "$LOCAL_DIR"/. "$HOME/.local"/
fi

# ------------------------------------------
# Default apps
# ------------------------------------------

if command -v xdg-mime &>/dev/null; then
    echo "==> Setting default applications..."
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    xdg-mime default imv-dir.desktop \
        image/png image/jpeg image/webp image/gif image/bmp image/tiff
fi

# ------------------------------------------
# Done
# ------------------------------------------

rm -f "$STATE_FILE"

echo
echo "=========================================="
echo " Dotfiles installation complete!"
echo "=========================================="

if ((${#MISSING_PACKAGES[@]} > 0)); then
    echo
    echo "==> These packages could not be installed:"

    for pkg in "${MISSING_PACKAGES[@]}"; do
        echo "    - $pkg"
    done
fi

if ((REBOOT_REQUIRED)); then
    echo
    echo "==> Display manager changed to greetd."
    echo "==> Test it before rebooting: sudo systemctl start greetd"
fi
