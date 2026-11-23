#!/usr/bin/env bash
# Run a command in the Arch Linux builder image for <tag>, with the checkout mounted at /src.
#   ./in-builder.sh x86_64 nu builder.nu plan
# IMAGE overrides the image (e.g. a locally built one). Secrets come from $SECRETS
# (default $RUNNER_TEMP/secrets): rclone.conf and signing.key.
set -euo pipefail
tag=$1; shift
repo=${GITHUB_REPOSITORY:-local/repo}
image=${IMAGE:-ghcr.io/${repo,,}-archlinux:$tag}
secrets=${SECRETS:-${RUNNER_TEMP:-/tmp}/secrets}
mkdir -p "$secrets"
exec docker run --rm \
    -v "$PWD:/src" -w /src \
    -v "$secrets:/secrets:ro" \
    -e RCLONE_CONFIG=/secrets/rclone.conf \
    -e SIGNING_KEY=/secrets/signing.key \
    "$image" "$@"
