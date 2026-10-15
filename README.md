# dotfiles

My personal Fedora desktop setup, plus the script that provisions my VPS.

- **Desktop**: Fedora with Umbriel (window manager), Noctalia (shell) and Noctalia Greeter (login screen).
- **Server**: [`vps-setup.sh`](./vps-setup.sh), a hardened Debian 13 server for rootless container apps.

## Desktop

Run:

```bash
curl -fsSL https://dotfiles.r3p.dev/install.sh | bash
```

The installer will:

- On Workstation, remove the apps listed in `packages/fedora-remove.txt` (most GNOME apps, LibreOffice, Ptyxis).
  GNOME itself stays as a fallback session
- Update the system with dnf
- Enable RPM Fusion, Terra, the COPR repositories (hyprpicker, yazi) and the vendor repositories (Brave, VS Code,
  GitHub CLI, cloudflared)
- Swap in the full ffmpeg and Mesa VA-API drivers
- Install the base system in `packages/fedora-base.txt` (audio, network, Bluetooth, fonts) and the packages in
  `packages/fedora.txt`
- Install the NVIDIA driver (`akmod-nvidia-open`) when an NVIDIA GPU is present. With Secure Boot enabled, this takes
  two runs: the first enrolls the signing key and reboots into MOK Manager, the second finishes the installation
- Install fnm, Bun and Rust (rustup) into the home directory with their official installers, then the crates in
  `packages/cargo.txt` (wl-screenrec) with `cargo install --locked`
- Configure greetd to start Noctalia Greeter, logging into Umbriel
- Set Fish as the default shell
- Install the wallpapers to `~/Pictures/Wallpapers`, the configuration files to `~/.config` and the files in `locals/`
  to `~/.local`, and make imv the default image viewer

The installer downloads the repository temporarily and removes it when finished. It does not clone the dotfiles
repository into your home directory.

### Requirements

A fresh Fedora installation and a user with `sudo`. It is written for Fedora Minimal (the Everything ISO with the
"Minimal Install" option), and also works on Workstation, which keeps GNOME as a second session to fall back on.
Everything else the installer needs, it installs itself.

## Server

`vps-setup.sh` turns a fresh Debian 13 (trixie) server into a single-user host for container apps: SSH keys only,
rootless Podman with Quadlet, Traefik with automatic HTTPS, an nftables firewall, fail2ban, and automatic security
updates. Afterwards it is installed as the `vps` command, which deploys apps from GitHub Actions and rolls them back
when a deploy is unhealthy.

On a fresh server, as root or a user with `sudo`, run:

```bash
curl -fsSL https://dotfiles.r3p.dev/vps-setup.sh | bash
```

Nothing in this repository is tied to a particular person: the script asks for your settings on the terminal (login
name, SSH key, SSH port, timezone, Let's Encrypt e-mail, GitHub owner), writes them to a temporary `vps.conf`, and runs
`init` with it. Leave the SSH key empty to keep the key you logged in with. `init` shows the plan and asks before it
changes anything.

Every setting in [`vps.conf`](./vps.conf) can also be given as an environment variable, which skips its question.
Set the required ones and it runs without questions (add `--yes` when there is no terminal, e.g. cloud-init):

```bash
curl -fsSL https://dotfiles.r3p.dev/vps-setup.sh |
  USER_NAME=admin GITHUB_OWNER=your-github ACME_EMAIL=you@example.org SSH_PORT=2222 bash -s -- --yes
```

Or bring a complete config file, which skips the questions: a `vps.conf` in the current directory is picked up by
itself, and any other file is given with `--config`:

```bash
curl -fsSL https://dotfiles.r3p.dev/vps-setup.sh | bash -s -- --config ~/my-vps.conf
```

The settings are saved to `/etc/vps/vps.conf` and the script installs itself as `/usr/local/bin/vps`. To change
something later, edit that file and run `sudo vps init`; nothing has to be downloaded again.

To update the script on a server that is already set up, run the same command. It finds `/etc/vps/vps.conf`, asks
nothing, and re-runs `init` with the saved settings (a `./vps.conf` is still layered on top, so remove a stale one).

To read the script before running it, download it first. `vps.conf` in this repository is the same template that
`config-example` prints:

```bash
curl -fsSLO https://dotfiles.r3p.dev/vps-setup.sh
bash vps-setup.sh config-example > vps.conf    # then edit it
sudo bash vps-setup.sh init --config vps.conf
```

Then run `vps help` as your user. The walkthrough is at
[r3p.dev/blogs/vps-setup-5](https://r3p.dev/blogs/vps-setup-5).

## Repository Structure

```text
.
├── configs/          copied to ~/.config/
├── locals/           copied to ~/.local/ (desktop entries)
├── packages/
│   ├── fedora-base.txt     base system, for Minimal
│   ├── fedora.txt          desktop and tools
│   ├── fedora-remove.txt   removed on Workstation
│   └── cargo.txt           installed with cargo install
├── wallpapers/       copied to ~/Pictures/Wallpapers/
├── install.sh        desktop installer
├── vps-setup.sh      server provisioning
├── vps.conf          server settings template (empty, same as config-example)
└── README.md
```

## Manual Installation

```bash
git clone https://github.com/r3p-dev/dotfiles.git
cd dotfiles
./install.sh
```

To update, `git pull` and run the installer again.

## Warning

This repository contains my personal system configuration. Review the scripts and configuration files before running
them on your own machine.

`install.sh` removes the apps in `packages/fedora-remove.txt`, runs `sudo dnf upgrade -y --refresh`, adds third-party
repositories, and installs every package in `packages/fedora-base.txt`, `packages/fedora.txt` and
`packages/cargo.txt`. `vps-setup.sh` rewrites the SSH, firewall and sudo configuration of the server it runs on.

Use at your own risk.
