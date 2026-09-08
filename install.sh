#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Dotfiles installer for EndeavourOS / Arch
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
CONFIGS_DIR="$SCRIPT_DIR/configs"

echo "==> Dotfiles installer"
echo "==> Source: GitHub"
echo

# ------------------------------------------
# Check OS
# ------------------------------------------

if [[ ! -f /etc/arch-release ]]; then
    echo "ERROR: This script is intended for Arch-based systems."
    exit 1
fi

# ------------------------------------------
# Check sudo
# ------------------------------------------

if ! command -v sudo &>/dev/null; then
    echo "ERROR: sudo is not installed."
    exit 1
fi

# ------------------------------------------
# Update system
# ------------------------------------------

echo "==> Updating system..."
sudo pacman -Syu --noconfirm

# ------------------------------------------
# Install official packages
# ------------------------------------------

if [[ -f "$OFFICIAL_PACKAGES" ]]; then
    echo "==> Installing official packages..."

    mapfile -t OFFICIAL < <(
        grep -vE '^[[:space:]]*(#|$)' "$OFFICIAL_PACKAGES"
    )

    if ((${#OFFICIAL[@]} > 0)); then
        sudo pacman -S --needed --noconfirm "${OFFICIAL[@]}"
    fi
else
    echo "WARNING: $OFFICIAL_PACKAGES not found."
fi

# ------------------------------------------
# Install AUR helper
# ------------------------------------------

if [[ -f "$AUR_PACKAGES" ]]; then

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
    # Install AUR packages
    # --------------------------------------

    echo "==> Installing AUR packages..."

    mapfile -t AUR < <(
        grep -vE '^[[:space:]]*(#|$)' "$AUR_PACKAGES"
    )

    if ((${#AUR[@]} > 0)); then
        yay -S --needed --noconfirm "${AUR[@]}"
    fi
else
    echo "WARNING: $AUR_PACKAGES not found."
fi

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

        sudo chsh -s "$FISH_PATH"

        echo "    -> Fish is now the default shell."
        echo "    -> Logout and login again to apply the change."
    else
        echo "==> Fish is already the default shell."
    fi
else
    echo "WARNING: fish was not found."
    echo "WARNING: Cannot set Fish as default shell."
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

if ((REBOOT_REQUIRED)); then
    echo
    echo "==> Display manager changed to greetd."
    echo "==> Reboot to start the Noctalia greeter."
fi
