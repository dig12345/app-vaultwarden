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

# --- settle on the Vaultwarden version to ship --------------------------------
# The Dockerfile can already be ahead of anything we would pick ourselves, when
# an upstream merge carried their own bump in. Take whichever is newer.
if [[ "${vw_current}" == "${vw_latest}" ]]; then
    vw_target="${vw_current}"
elif [[ "$(printf '%s\n%s\n' "${vw_current}" "${vw_latest}" | sort -V | tail -1)" == "${vw_latest}" ]]; then
    vw_target="${vw_latest}"
    sed -i -E "s|^FROM \"vaultwarden/server:.+\" AS vaultwarden\$|FROM \"vaultwarden/server:${vw_target}\" AS vaultwarden|" "${DOCKERFILE}"
else
    echo "::warning::Latest tag ${vw_latest} sorts below the Dockerfile's ${vw_current}; keeping ${vw_current}"
    vw_target="${vw_current}"
fi

# --- decide the new add-on version --------------------------------------------
# The add-on version tracks the Vaultwarden version it ships (1.37.3). A
# trailing -N distinguishes rebuilds carrying the same Vaultwarden (1.37.3-2).
# Comparing against the base is what keeps the two from drifting apart when the
# Dockerfile bump arrived via a merge rather than from this script.
if [[ "${addon_current}" =~ ^(.+)-([0-9]+)$ ]]; then
    addon_base="${BASH_REMATCH[1]}"
    addon_suffix="${BASH_REMATCH[2]}"
else
    addon_base="${addon_current}"
    addon_suffix=1
fi

if [[ "${addon_base}" != "${vw_target}" ]]; then
    addon_new="${vw_target}"
elif [[ "${glue_changed}" == true ]]; then
    addon_new="${addon_base}-$((addon_suffix + 1))"
else
    echo "Already shipping ${vw_target} as ${addon_current}; nothing to do."
    emit changed false
    exit 0
fi

sed -i -E "s|^version: .+\$|version: ${addon_new}|" "${CONFIG}"
emit addon_new "${addon_new}"
emit changed true
