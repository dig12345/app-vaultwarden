#!/usr/bin/env bash
# ==============================================================================
# Resolves the newest stable vaultwarden/server release and rewrites the
# Dockerfile + add-on version to match.
#
# Usage: update-version.sh [--glue-changed]
#   --glue-changed  Upstream brought in non-Dockerfile changes this run, so the
#                   add-on version needs a bump even if Vaultwarden did not move.
#
# Emits to $GITHUB_OUTPUT (when set): changed, vw_current, vw_latest,
# addon_current, addon_new
# ==============================================================================
set -euo pipefail

DOCKERFILE="vaultwarden/Dockerfile"
CONFIG="vaultwarden/config.yaml"
glue_changed=false
[[ "${1:-}" == "--glue-changed" ]] && glue_changed=true

emit() { [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$1=$2" >>"${GITHUB_OUTPUT}"; echo "$1=$2"; }

# --- current state ------------------------------------------------------------
vw_current=$(sed -nE 's/^FROM "vaultwarden\/server:(.+)" AS vaultwarden$/\1/p' "${DOCKERFILE}")
addon_current=$(sed -nE 's/^version: (.+)$/\1/p' "${CONFIG}")

if [[ -z "${vw_current}" || -z "${addon_current}" ]]; then
    echo "::error::Could not parse current versions (vw='${vw_current}' addon='${addon_current}')"
    exit 1
fi

# --- newest stable upstream release -------------------------------------------
# Only bare X.Y.Z tags: skips latest/testing/alpine and any prerelease suffix.
vw_latest=$(
    for page in 1 2; do
        curl -fsSL --retry 3 --retry-delay 5 \
            "https://hub.docker.com/v2/repositories/vaultwarden/server/tags?page_size=100&page=${page}" |
            python3 -c 'import json,sys; [print(t["name"]) for t in json.load(sys.stdin)["results"]]'
    done | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
)

if [[ -z "${vw_latest}" ]]; then
    echo "::error::Could not determine latest vaultwarden/server tag from Docker Hub"
    exit 1
fi

emit vw_current "${vw_current}"
emit vw_latest "${vw_latest}"
emit addon_current "${addon_current}"

# --- decide the new add-on version --------------------------------------------
# Vaultwarden moved   -> add-on version tracks it exactly (1.37.1)
# glue-only change    -> append/increment a build suffix (1.37.1 -> 1.37.1-2)
if [[ "${vw_current}" != "${vw_latest}" ]]; then
    if [[ "$(printf '%s\n%s\n' "${vw_current}" "${vw_latest}" | sort -V | tail -1)" != "${vw_latest}" ]]; then
        echo "::warning::Latest tag ${vw_latest} sorts below current ${vw_current}; refusing to downgrade"
        emit changed false
        exit 0
    fi
    sed -i -E "s|^FROM \"vaultwarden/server:.+\" AS vaultwarden\$|FROM \"vaultwarden/server:${vw_latest}\" AS vaultwarden|" "${DOCKERFILE}"
    addon_new="${vw_latest}"
elif [[ "${glue_changed}" == true ]]; then
    if [[ "${addon_current}" =~ ^(.+)-([0-9]+)$ ]]; then
        addon_new="${BASH_REMATCH[1]}-$((BASH_REMATCH[2] + 1))"
    else
        addon_new="${addon_current}-2"
    fi
else
    echo "Already on ${vw_current}; no upstream changes to ship."
    emit changed false
    exit 0
fi

sed -i -E "s|^version: .+\$|version: ${addon_new}|" "${CONFIG}"
emit addon_new "${addon_new}"
emit changed true
