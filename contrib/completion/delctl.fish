# Fish completion for delctl.

# `__fish_use_subcommand` keeps the commands from being offered twice, since
# delctl takes exactly one.
complete -c delctl -f

complete -c delctl -n __fish_use_subcommand -a outputs -d "Connected outputs and their geometry"
complete -c delctl -n __fish_use_subcommand -a workspaces -d "Every workspace that exists"
complete -c delctl -n __fish_use_subcommand -a windows -d "Every window delta knows about"
complete -c delctl -n __fish_use_subcommand -a focused -d "The focused window, if any"
complete -c delctl -n __fish_use_subcommand -a version -d "delta's version"
complete -c delctl -n __fish_use_subcommand -a watch -d "Follow state changes until interrupted"

complete -c delctl -l json -d "Print delta's reply verbatim"
complete -c delctl -s h -l help -d "Print usage"
