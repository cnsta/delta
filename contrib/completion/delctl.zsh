#compdef delctl deltactl
# Zsh completion for delctl.

_delctl() {
  local -a commands
  commands=(
    'outputs:Connected outputs and their geometry'
    'workspaces:Every workspace that exists'
    'windows:Every window delta knows about'
    'focused:The focused window, if any'
    "version:delta's version"
    'watch:Follow state changes until interrupted'
  )

  _arguments -C \
    '--json[Print delta'"'"'s reply verbatim]' \
    '(-h --help)'{-h,--help}'[Print usage]' \
    '1: :->command'

  case "$state" in
  command)
    _describe -t commands 'delctl command' commands
    ;;
  esac
}
