#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT}/common/lib.sh"

entry_for() {
    local dir="$1" name lower c
    name="$(basename "${dir}")"
    lower="$(echo "${name}" | tr '[:upper:]' '[:lower:]')"
    for c in "${dir}/${name}.sh" "${dir}/${lower}.sh" "${dir}/main.sh" "${dir}/run.sh"; do
        [[ -f "${c}" ]] && { echo "${c}"; return 0; }
    done
    return 1
}

list_tools() {
    local d
    for d in "${ROOT}"/*/; do
        d="${d%/}"
        [[ "$(basename "${d}")" == "common" ]] && continue
        entry_for "${d}" >/dev/null || continue
        printf '  %s\n' "$(basename "${d}")"
    done
}

resolve_tool_dir() {
    local want="$1" d
    [[ -d "${ROOT}/${want}" ]] && entry_for "${ROOT}/${want}" >/dev/null && { echo "${ROOT}/${want}"; return 0; }
    local lower; lower="$(echo "${want}" | tr '[:upper:]' '[:lower:]')"
    for d in "${ROOT}"/*/; do
        d="${d%/}"
        [[ "$(basename "${d}")" == "common" ]] && continue
        if [[ "$(basename "${d}" | tr '[:upper:]' '[:lower:]')" == "${lower}" ]]; then
            entry_for "${d}" >/dev/null && { echo "${d}"; return 0; }
        fi
    done
    return 1
}

usage() {
    cat <<EOF
Usage: ./tools.sh <tool> [args...]
       ./tools.sh list

Available tools:
$(list_tools)

Run './tools.sh <tool>' with no extra arguments to see that tool's own help.
EOF
}

tool="${1:-}"
case "${tool}" in
    ""|-h|--help|help) usage; exit 0 ;;
    list) echo "Available tools:"; list_tools; exit 0 ;;
esac

dir="$(resolve_tool_dir "${tool}")" || die "unknown tool: ${tool} (try './tools.sh list')"
entry="$(entry_for "${dir}")" || die "no entry script in $(basename "${dir}")/"
shift
exec bash "${entry}" "$@"
