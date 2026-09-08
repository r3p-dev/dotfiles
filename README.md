# dotfiles

My personal dotfiles and Arch Linux setup.

Designed for Arch-based systems such as Arch Linux and EndeavourOS.

## Installation

Run:

```bash
curl -fsSL https://dotfiles.r3p.dev/install.sh | bash
```

The installer will:

- Update the system with pacman
- Install official packages
- Install yay if needed
- Install AUR packages
- Set Fish as the default shell
- Install configuration files to ~/.config

The installer downloads the repository temporarily and removes it when finished. It does not clone the dotfiles repository into your home directory.

## Repository Structure

```
.
├── configs/
│   └── ...
├── packages/
│   ├── official.txt
│   └── aur.txt
├── install.sh
└── README.md
```

### `configs/`

Contains configuration files and directories that are copied to:

```
~/.config/
```

### `packages/official.txt`

List of packages available from the official Arch repositories.

### `packages/aur.txt`

List of packages installed from the AUR using yay.

### `install.sh`

Main installation script.

## Manual Installation

Clone the repository:

```bash
git clone https://github.com/r3p-dev/dotfiles.git
cd dotfiles
```

Then run:

```bash
./install.sh
```

Or:

```bash
bash install.sh
```

## Requirements

The target system must be an Arch-based Linux distribution.

The installer expects:

- bash
- curl
- sudo
- git

yay does not need to be installed beforehand. The installer will install it automatically when AUR packages are present.

## Updating

To update the dotfiles repository:

```bash
git pull
```

Then run the installer again:

```bash
./install.sh
```

## Warning

This repository contains my personal system configuration.

Review the scripts and configuration files before running the installer on your own system.

The installer uses:

```bash
sudo pacman -Syu --noconfirm
```

and installs packages listed in packages/official.txt and packages/aur.txt.

Use at your own risk.
