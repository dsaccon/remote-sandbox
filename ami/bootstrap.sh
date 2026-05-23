#!/usr/bin/env bash
# ami/bootstrap.sh — runs inside a fresh Ubuntu 24.04 VM during AMI bake.
# Invoked by `sandbox build-ami` over SSH. Expects to be running as a user
# with passwordless sudo.

set -euo pipefail

DOTFILES_REPO="${DOTFILES_REPO:-}"

log() { printf '[bootstrap %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

log "apt update + base packages"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release \
    git tmux htop jq ripgrep fd-find fzf unzip build-essential \
    python3 python3-pip python-is-python3 \
    shellcheck bats

log "Node.js LTS (NodeSource)"
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo npm install -g pnpm

log "bun"
curl -fsSL https://bun.sh/install | bash
# Move bun into /usr/local/bin so all shells see it.
sudo install -m 0755 ~/.bun/bin/bun /usr/local/bin/bun
rm -rf ~/.bun

log "uv (Astral)"
curl -LsSf https://astral.sh/uv/install.sh | sh
sudo install -m 0755 ~/.local/bin/uv /usr/local/bin/uv
sudo install -m 0755 ~/.local/bin/uvx /usr/local/bin/uvx 2>/dev/null || true

log "Docker Engine"
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker ubuntu

log "GitHub CLI"
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
sudo apt-get update -y
sudo apt-get install -y gh

log "claude code CLI"
# Official install one-liner — uses npm under the hood, installs to /usr/local.
sudo npm install -g @anthropic-ai/claude-code

log "fd alias (Ubuntu names it fdfind)"
sudo ln -sf /usr/bin/fdfind /usr/local/bin/fd

log "neovim (latest stable from neovim/neovim releases — Ubuntu's apt nvim is too old for LazyVim)"
# Pin a known-good URL pattern; arch is amd64 only per AMI design.
nvim_tar=/tmp/nvim-linux-x86_64.tar.gz
curl -fsSL -o "$nvim_tar" \
    https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
sudo tar -C /opt -xzf "$nvim_tar"
sudo ln -sf /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim
rm -f "$nvim_tar"

log "xterm-ghostty terminfo (Ubuntu 24.04 ships ncurses 6.4, which lacks it)"
# System-wide so it works for any user / sudo session.
sudo tic -x -o /etc/terminfo /tmp/xterm-ghostty.src

log "systemd auto-shutdown unit"
sudo install -m 0644 /tmp/auto-shutdown.service /etc/systemd/system/auto-shutdown.service
sudo install -m 0644 /tmp/auto-shutdown.timer   /etc/systemd/system/auto-shutdown.timer

if [[ -n "$DOTFILES_REPO" ]]; then
    log "dotfiles: $DOTFILES_REPO"
    sudo -u ubuntu git clone "$DOTFILES_REPO" /home/ubuntu/dotfiles
    # If there's an install.sh, run it; otherwise leave it for the user.
    if [[ -x /home/ubuntu/dotfiles/install.sh ]]; then
        sudo -u ubuntu bash -lc 'cd ~/dotfiles && ./install.sh'
    fi
fi

log "cleanup apt cache to shrink AMI"
sudo apt-get autoremove -y
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

log "done"
