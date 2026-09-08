set --erase fish_greeting
fish_add_path $HOME/.local/bin

if status is-interactive
    zoxide init fish | source
    starship init fish | source
end
