#!/bin/bash
# Resolve origin without consulting a separate release repository setting.
github_repository() {
    local origin
    if [[ "$#" == 0 ]]; then set -- origin; fi
    origin="$(git remote get-url "$@")" || return
    case "$origin" in
        https://github.com/*) origin="${origin#https://github.com/}" ;;
        git@github.com:*) origin="${origin#git@github.com:}" ;;
        ssh://git@github.com/*) origin="${origin#ssh://git@github.com/}" ;;
        *) echo "origin must point to a github.com repository." >&2; return 1 ;;
    esac
    origin="${origin%/}"
    origin="${origin%.git}"
    if [[ ! "$origin" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*/[a-zA-Z0-9_.-]+$ ||
          "${origin#*/}" == "." || "${origin#*/}" == ".." ]]; then
        echo "Could not determine the GitHub owner and repository from origin." >&2
        return 1
    fi
    printf '%s\n' "$origin"
}
