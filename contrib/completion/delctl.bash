# Bash completion for delctl.

_delctl() {
  local cur prev commands options
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"

  commands="outputs workspaces windows focused version watch"
  options="--json -h --help"

  # One command per invocation. Once it is present, only options remain.
  local word has_command=0
  for word in "${COMP_WORDS[@]:1:COMP_CWORD-1}"; do
    case " $commands " in
    *" $word "*) has_command=1 ;;
    esac
  done

  if [[ $cur == -* ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$options" -- "$cur")
    return 0
  fi

  if [[ $has_command -eq 0 ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$commands" -- "$cur")
  fi

  return 0
} && complete -F _delctl delctl deltactl
