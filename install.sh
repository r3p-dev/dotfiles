#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Dotfiles installer -- Fedora
#
# Dijalankan dua tahap HANYA kalau perlu: mesin ber-NVIDIA dengan
# Secure Boot aktif harus reboot untuk mendaftarkan kunci MOK sebelum
# modul kernel bisa dimuat. Di luar itu, sekali jalan sampai selesai.
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
# Pastikan ini Fedora
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
# Minta password sekarang, selagi masih ada yang menunggu di depan
# layar. Kalau prompt-nya muncul di tengah instalasi paket, dia gampang
# terlewat dan sudo keburu timeout.

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
# Minimal Install (@core) tidak membawa tar, git, maupun pciutils, dan
# ketiganya dibutuhkan sebelum apa pun yang lain -- termasuk lspci
# untuk mendeteksi NVIDIA.

BOOTSTRAP_TOOLS=()

for tool in curl tar git lspci; do
    command -v "$tool" &>/dev/null || BOOTSTRAP_TOOLS+=("$tool")
done

if ((${#BOOTSTRAP_TOOLS[@]} > 0)); then
    echo "==> Installing bootstrap tools: ${BOOTSTRAP_TOOLS[*]}"

    # lspci hidup di paket bernama pciutils.
    sudo dnf install -y "${BOOTSTRAP_TOOLS[@]/lspci/pciutils}"
fi

# ------------------------------------------
# Deteksi hardware
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
    # mokutil belum ada; baca langsung dari variabel EFI. Byte terakhir
    # SecureBoot bernilai 1 kalau aktif.
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
# Deteksi tahap
# ------------------------------------------

STAGE=1

[[ -f "$STATE_FILE" ]] && STAGE="$(cat "$STATE_FILE")"

# ==========================================
# TAHAP 1 -- pendaftaran kunci MOK
# ==========================================
#
# Hanya relevan untuk NVIDIA dengan Secure Boot. Modul yang dibangun
# akmods ditandatangani kunci lokal, dan kunci itu harus terdaftar di
# firmware sebelum kernel mau memuatnya. Pendaftarannya butuh reboot
# dan konfirmasi manual di layar biru MOK Manager.

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
# TAHAP 2 -- instalasi penuh
# ==========================================

echo "==> Downloading dotfiles..."

curl -fsSL "$REPO" | tar -xz -C "$TEMP_DIR"

SCRIPT_DIR="$TEMP_DIR/dotfiles-main"

FEDORA_PACKAGES="$SCRIPT_DIR/packages/fedora.txt"
FEDORA_BASE_PACKAGES="$SCRIPT_DIR/packages/fedora-base.txt"
CARGO_PACKAGES="$SCRIPT_DIR/packages/cargo.txt"
CONFIGS_DIR="$SCRIPT_DIR/configs"

read_package_list() {
    local file="$1"

    [[ -f "$file" ]] || return 1

    grep -vE '^[[:space:]]*(#|$)' "$file" | sed 's/[[:space:]]*#.*$//'
}

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
    # dnf5 (Fedora 41+) memakai "addrepo", dnf4 memakai "--add-repo".

    local url="$1"

    sudo dnf config-manager addrepo --from-repofile="$url" 2>/dev/null ||
        sudo dnf config-manager --add-repo "$url"
}

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
# Fedora mengirim ffmpeg-free yang dipangkas (tanpa H.264/H.265/AAC).
# Paket penuh dari RPM Fusion bentrok dengannya, jadi harus 'swap',
# bukan 'install' -- itu sebabnya ffmpeg tidak ada di fedora.txt.

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

# Sama seperti ffmpeg: driver VA-API Mesa bawaan Fedora dipangkas, dan
# versi lengkapnya dari RPM Fusion bentrok -- jadi swap, bukan install.
# Ini yang dipakai iGPU AMD untuk decode video berakselerasi.

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
# hyprpicker tidak ada di repo resmi Fedora.

echo "==> Enabling COPR repositories..."

# dnf5 memisahkan subperintah copr ke paket plugin tersendiri.
sudo dnf install -y dnf5-plugins 2>/dev/null ||
    sudo dnf install -y dnf-plugins-core ||
    echo "WARNING: dnf plugins install failed; copr may be unavailable."

sudo dnf -y copr enable lionheartp/Hyprland ||
    echo "WARNING: COPR lionheartp/Hyprland failed; hyprpicker will be missing."

# ------------------------------------------
# Repo vendor
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

if [[ ! -f /etc/yum.repos.d/tailscale.repo ]]; then
    add_repo_file https://pkgs.tailscale.com/stable/fedora/tailscale.repo ||
        echo "WARNING: Tailscale repository setup failed."
fi

# ------------------------------------------
# Paket
# ------------------------------------------
#
# Base system hanya berguna di instalasi minimal; di Workstation
# semuanya sudah ada dan dnf akan melewatinya.

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
# Driver NVIDIA
# ------------------------------------------
#
# akmod membangun modul terhadap kernel terpasang, dan itu jalan di
# latar belakang setelah paketnya masuk. Reboot sebelum build selesai
# menghasilkan boot tanpa driver, jadi tunggu sampai modulnya ada.

if ((HAS_NVIDIA)); then
    echo "==> Installing NVIDIA driver..."

    # Varian "open" menyamai nvidia-open di Arch, dan itu yang
    # direkomendasikan NVIDIA untuk Turing ke atas.

    dnf_install \
        akmod-nvidia-open \
        xorg-x11-drv-nvidia-cuda \
        libva-nvidia-driver \
        libva-utils \
        vdpauinfo

    # Tandai sebagai paket yang diminta user supaya tidak ikut terhapus
    # saat autoremove membersihkan dependensi.
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
# Flatpak
# ------------------------------------------

if command -v flatpak &>/dev/null; then
    echo "==> Installing Spotify via Flatpak..."

    flatpak remote-add --if-not-exists --user \
        flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true

    flatpak install -y --user flathub com.spotify.Client ||
        MISSING_PACKAGES+=("com.spotify.Client (flatpak)")
else
    MISSING_PACKAGES+=("flatpak (dibutuhkan untuk Spotify)")
fi

# ------------------------------------------
# Crate Rust
# ------------------------------------------
#
# yazi, resvg, satty dan wl-screenrec tidak dikemas untuk Fedora.
# Build-dep-nya dipasang duluan: satty butuh GTK4, wl-screenrec butuh
# header ffmpeg/VA-API plus clang untuk bindgen.

if [[ -f "$CARGO_PACKAGES" ]]; then
    echo "==> Installing Rust toolchain and build dependencies..."

    CARGO_BUILD_DEPS=(
        cargo
        rust
        clang
        pkgconf-pkg-config
        gtk4-devel
        libadwaita-devel
        ffmpeg-devel
        libva-devel
    )

    dnf_install "${CARGO_BUILD_DEPS[@]}"

    echo "==> Installing Rust crates (this takes a while)..."

    mapfile -t CRATES < <(read_package_list "$CARGO_PACKAGES")

    for crate in "${CRATES[@]}"; do
        echo "    -> $crate"

        cargo install --locked "$crate" ||
            MISSING_PACKAGES+=("$crate (cargo)")
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

    # Akun yang menjalankan greeter beda nama antar distro: paket Arch
    # membuat "greeter", RPM Fedora membuat "greetd" lewat sysusers.d.
    # Salah nama -> greetd mati seketika dengan "session user not found".

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
command = "$GREETER_SESSION"
user = "$GREETER_USER"
EOF

    # Greeter menulis config dan log-nya di sini; pemilik yang salah
    # menghasilkan layar hitam walau service-nya terlihat aktif.

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

    # Instalasi minimal Fedora default-nya multi-user.target, jadi boot
    # berhenti di TTY dan greetd tidak pernah dijalankan.

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
# Fish sebagai shell default
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

        # chsh hidup di util-linux-user, yang tidak terpasang secara
        # default di Fedora.

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

FASTFETCH_CONFIG="$HOME/.config/fastfetch/config.jsonc"

if [[ -f "$FASTFETCH_CONFIG" ]]; then
    sed -i 's/"endeavouros_small"/"fedora_small"/' "$FASTFETCH_CONFIG"
fi

# ------------------------------------------
# Selesai
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
