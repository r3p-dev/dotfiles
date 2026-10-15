set -l fnm_path $HOME/.local/share/fnm

if test -d $fnm_path
    fish_add_path $fnm_path
    fnm env --use-on-cd --shell fish | source
end
