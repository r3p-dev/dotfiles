#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Dotfiles installer
# Arch / EndeavourOS  +  Fedora
# ==========================================

REPO="https://github.com/r3p-dev/dotfiles/archive/refs/heads/main.tar.gz"
TEMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

echo "==> Downloading dotfiles..."

curl -fsSL "$REPO" | tar -xz -C "$TEMP_DIR"

SCRIPT_DIR="$TEMP_DIR/dotfiles-main"

OFFICIAL_PACKAGES="$SCRIPT_DIR/packages/official.txt"
AUR_PACKAGES="$SCRIPT_DIR/packages/aur.txt"
FEDORA_PACKAGES="$SCRIPT_DIR/packages/fedora.txt"
FEDORA_BASE_PACKAGES="$SCRIPT_DIR/packages/fedora-base.txt"
CONFIGS_DIR="$SCRIPT_DIR/configs"

MISSING_PACKAGES=()

echo "==> Dotfiles installer"
echo "==> Source: GitHub"
echo

# ------------------------------------------
# Detect distro
# ------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: /etc/os-release not found. Unsupported system."
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

DISTRO=""

case "$ID" in
    arch | endeavouros | cachyos) DISTRO="arch" ;;
    fedora) DISTRO="fedora" ;;
    *)
        case "${ID_LIKE:-}" in
            *arch*) DISTRO="arch" ;;
            *fedora*) DISTRO="fedora" ;;
        esac
        ;;
esac

if [[ -z "$DISTRO" ]]; then
    echo "ERROR: Unsupported distribution: $ID"
    echo "ERROR: This script supports Arch-based and Fedora systems."
    exit 1
fi

echo "==> Detected: $PRETTY_NAME ($DISTRO)"

# ------------------------------------------
# Check sudo
# ------------------------------------------

if ! command -v sudo &>/dev/null; then
    echo "ERROR: sudo is not installed."
    exit 1
fi

# ------------------------------------------
# Read a package list into an array
# ------------------------------------------

read_package_list() {
    local file="$1"

    [[ -f "$file" ]] || return 1

    grep -vE '^[[:space:]]*(#|$)' "$file" | sed 's/[[:space:]]*#.*$//'
}

# ==========================================
# Arch branch
# ==========================================

install_arch() {
    echo "==> Updating system..."
    sudo pacman -Syu --noconfirm

    # --------------------------------------
    # Official packages
    # --------------------------------------

    if [[ -f "$OFFICIAL_PACKAGES" ]]; then
        echo "==> Installing official packages..."

        mapfile -t OFFICIAL < <(read_package_list "$OFFICIAL_PACKAGES")

        if ((${#OFFICIAL[@]} > 0)); then
            sudo pacman -S --needed --noconfirm "${OFFICIAL[@]}"
        fi
    else
        echo "WARNING: $OFFICIAL_PACKAGES not found."
    fi

    # --------------------------------------
    # AUR helper
    # --------------------------------------

    [[ -f "$AUR_PACKAGES" ]] || return 0

    if ! command -v yay &>/dev/null; then
        echo "==> yay is not installed."
        echo "==> Installing yay..."

        TEMP_YAY="$(mktemp -d)"

        git clone https://aur.archlinux.org/yay.git "$TEMP_YAY/yay"

        (
            cd "$TEMP_YAY/yay"
            makepkg -si --noconfirm
        )

        rm -rf "$TEMP_YAY"
    fi

    # --------------------------------------
    # AUR packages
    # --------------------------------------

    echo "==> Installing AUR packages..."

    mapfile -t AUR < <(read_package_list "$AUR_PACKAGES")

    if ((${#AUR[@]} > 0)); then
        yay -S --needed --noconfirm "${AUR[@]}"
    fi
}

# ==========================================
# Fedora branch
# ==========================================

dnf_install() {
    # Coba sekali jalan dulu. Kalau ada satu nama paket yang tidak
    # tersedia dnf membatalkan seluruh transaksi, jadi fallback-nya
    # pasang satu per satu dan catat yang gagal.

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

install_fedora() {
    echo "==> Updating system..."
    sudo dnf upgrade -y --refresh

    # --------------------------------------
    # RPM Fusion (ffmpeg, codec)
    # --------------------------------------

    echo "==> Enabling RPM Fusion..."

    sudo dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$VERSION_ID.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$VERSION_ID.noarch.rpm" ||
        echo "WARNING: RPM Fusion setup failed; ffmpeg/mpv may be limited."

    # --------------------------------------
    # Codec
    # --------------------------------------

    echo "==> Swapping to full ffmpeg..."
 
    sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing ||
        echo "WARNING: ffmpeg swap failed; codec support will be limited."
 
    echo "==> Installing multimedia groups..."
 
    sudo dnf group upgrade -y multimedia \
        --setopt="install_weak_deps=False" \
        --exclude=PackageKit-gstreamer-plugin ||
        echo "WARNING: multimedia group upgrade failed."
 
    sudo dnf group upgrade -y sound-and-video ||
        echo "WARNING: sound-and-video group upgrade failed."

    # --------------------------------------
    # Terra (umbriel-nightly, noctalia-greeter)
    # --------------------------------------

    echo "==> Enabling Terra..."

    sudo dnf install -y --nogpgcheck \
        --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
        terra-release ||
        echo "WARNING: Terra setup failed; umbriel/noctalia-greeter will be missing."

    # --------------------------------------
    # Vendor repos
    # --------------------------------------

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

    if [[ ! -f /etc/yum.repos.d/tailscale.repo ]]; then
        add_repo_file https://pkgs.tailscale.com/stable/fedora/tailscale.repo ||
            echo "WARNING: Tailscale repository setup failed."
    fi

    # --------------------------------------
    # Packages
    # --------------------------------------

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
}

# ------------------------------------------
# Run the branch for this distro
# ------------------------------------------

case "$DISTRO" in
    arch) install_arch ;;
    fedora) install_fedora ;;
esac

# ------------------------------------------
# Setup Noctalia greeter (greetd)
# ------------------------------------------

GREETER_SESSION="$(command -v noctalia-greeter-session || true)"
REBOOT_REQUIRED=0

if [[ -n "$GREETER_SESSION" ]]; then
    echo "==> Configuring Noctalia greeter..."

    sudo install -d /etc/greetd

    echo "    -> Writing /etc/greetd/config.toml"

    sudo tee /etc/greetd/config.toml >/dev/null <<EOF
[terminal]
vt = 1

[default_session]
command = "$GREETER_SESSION"
user = "greeter"
EOF

    DM_LINK="/etc/systemd/system/display-manager.service"

    if [[ -L "$DM_LINK" ]]; then
        CURRENT_DM="$(basename "$(readlink -f "$DM_LINK")")"

        if [[ "$CURRENT_DM" != "greetd.service" ]]; then
            echo "    -> Disabling $CURRENT_DM"
            sudo systemctl disable "$CURRENT_DM"
        fi
    fi

    echo "    -> Enabling greetd"
    sudo systemctl enable greetd

    REBOOT_REQUIRED=1
else
    echo "WARNING: noctalia-greeter-session was not found."
    echo "WARNING: Skipping greetd configuration."
fi

# ------------------------------------------
# Set Fish as default shell
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

        if command -v chsh &>/dev/null; then
            sudo chsh -s "$FISH_PATH" "$USER"

            echo "    -> Fish is now the default shell."
            echo "    -> Logout and login again to apply the change."
        else
            echo "WARNING: chsh not found (install util-linux-user on Fedora)."
        fi
    else
        echo "==> Fish is already the default shell."
    fi
else
    echo "WARNING: fish was not found."
    echo "WARNING: Cannot set Fish as default shell."
fi

# ------------------------------------------
# Install wallpapers
# ------------------------------------------

WALLPAPERS_DIR="$SCRIPT_DIR/wallpapers"
WALLPAPERS_TARGET="$HOME/Pictures/Wallpapers"

if [[ -d "$WALLPAPERS_DIR" ]]; then
    echo "==> Installing wallpapers..."
    mkdir -p "$WALLPAPERS_TARGET"
    cp -a "$WALLPAPERS_DIR"/. "$WALLPAPERS_TARGET"/
else
    echo "WARNING: $WALLPAPERS_DIR not found."
fi

# ------------------------------------------
# Install configs
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
# Done
# ------------------------------------------

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

    echo "==> Install them manually (cargo, flatpak, or another repo)."
fi

if ((REBOOT_REQUIRED)); then
    echo
    echo "==> Display manager changed to greetd."
    echo "==> Reboot to start the Noctalia greeter."
fi
