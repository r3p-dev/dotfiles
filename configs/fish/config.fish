set fish_greeting
fish_add_path $HOME/.local/bin

if status is-interactive
    zoxide init fish | source
    starship init fish | source
end

set -gx SSH_AUTH_SOCK $XDG_RUNTIME_DIR/ssh-agent.socket
