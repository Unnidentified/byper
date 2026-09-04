# Bash completion for byp and chbypass

_byp_complete() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="on off t mon s lpm json help"

    case "${prev}" in
        byp|chbypass)
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        lpm)
            COMPREPLY=( $(compgen -W "1 0 on off" -- "${cur}") )
            return 0
            ;;
        json)
            COMPREPLY=( $(compgen -W "--watch -w" -- "${cur}") )
            return 0
            ;;
        mon)
            COMPREPLY=( $(compgen -W "--export -e" -- "${cur}") )
            return 0
            ;;
        *)
            ;;
    esac
}

complete -F _byp_complete byp
complete -F _byp_complete chbypass
