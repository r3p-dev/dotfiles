#!/usr/bin/env bash

set -euo pipefail

# ==========================================
# Dotfiles installer for EndeavourOS / Arch
# ==========================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

OFFICIAL_PACKAGES="$SCRIPT_DIR/packages/official.txt"
AUR_PACKAGES="$SCRIPT_DIR/packages/aur.txt"
CONFIGS_DIR="$SCRIPT_DIR/configs"

echo "==> Dotfiles installer"
echo "==> Repository: $SCRIPT_DIR"
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

        TEMP_DIR="$(mktemp -d)"

        trap 'rm -rf "$TEMP_DIR"' EXIT

        git clone https://aur.archlinux.org/yay.git "$TEMP_DIR/yay"

        (
            cd "$TEMP_DIR/yay"
            makepkg -si --noconfirm
        )
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

        chsh -s "$FISH_PATH"

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
