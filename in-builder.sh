#!/usr/bin/env bash
# Run a command in the Arch Linux builder image for <tag>, with the checkout mounted at /src.
#   ./in-builder.sh x86_64 nu builder.nu plan
# IMAGE overrides the image (e.g. a locally built one). Every RCLONE_* variable is passed
# through, so the remote can be defined with RCLONE_CONFIG_<NAME>_<OPTION>. Files come from
# $SECRETS (default $RUNNER_TEMP/secrets): signing.key, and rclone.conf if you'd rather use one.
set -euo pipefail
tag=$1; shift
repo=${GITHUB_REPOSITORY:-local/repo}
image=${IMAGE:-ghcr.io/${repo,,}-archlinux:$tag}
secrets=${SECRETS:-${RUNNER_TEMP:-/tmp}/secrets}
mkdir -p "$secrets"
# `-e NAME` without a value: docker copies it from this environment, so it stays off the command line
env_args=()
for v in $(compgen -e | grep '^RCLONE_' || true); do env_args+=(-e "$v"); done
[[ -f $secrets/rclone.conf ]] && env_args+=(-e RCLONE_CONFIG=/secrets/rclone.conf)
exec docker run --rm \
    -v "$PWD:/src" -w /src \
    -v "$secrets:/secrets:ro" \
    "${env_args[@]}" \
    -e SIGNING_KEY=/secrets/signing.key \
    "$image" "$@"
