# Bash completion for byp and chbypass

_byp_complete() {
    local cur
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"

    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "on off t mon s lpm caffeinate lid logger auto json help" -- "${cur}") )
        return 0
    fi

    case "${COMP_WORDS[1]}" in
        lpm)
            COMPREPLY=( $(compgen -W "1 0 on off" -- "${cur}") )
            ;;
        caffeinate)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "on off auto status" -- "${cur}") )
            elif [[ ${COMP_WORDS[2]} == auto ]]; then
                COMPREPLY=( $(compgen -W "on off" -- "${cur}") )
            fi
            ;;
        lid)
            COMPREPLY=( $(compgen -W "on off status" -- "${cur}") )
            ;;
        logger)
            COMPREPLY=( $(compgen -W "--quiet" -- "${cur}") )
            ;;
        auto)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "run plug login display off-on-exit lpm" -- "${cur}") )
            else
                case "${COMP_WORDS[2]}" in
                    run)
                        COMPREPLY=( $(compgen -W "--quiet --force" -- "${cur}") )
                        ;;
                    plug|login|display|off-on-exit)
                        COMPREPLY=( $(compgen -W "on off" -- "${cur}") )
                        ;;
                    lpm)
                        if [[ ${COMP_CWORD} -eq 3 ]]; then
                            COMPREPLY=( $(compgen -W "add remove list clear" -- "${cur}") )
                        fi
                        ;;
                esac
            fi
            ;;
        json)
            COMPREPLY=( $(compgen -W "--watch -w" -- "${cur}") )
            ;;
        mon)
            COMPREPLY=( $(compgen -W "--export -e" -- "${cur}") )
            ;;
    esac
    return 0
}

complete -F _byp_complete byp
complete -F _byp_complete chbypass
