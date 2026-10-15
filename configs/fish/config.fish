set fish_greeting
fish_add_path $HOME/.local/bin

if status is-interactive
    zoxide init fish | source
    starship init fish | source
end

set --export BUN_INSTALL "$HOME/.bun"
set --export PATH $BUN_INSTALL/bin $PATH
