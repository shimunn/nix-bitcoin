#!/usr/bin/env bash

# Usage:
#
#   run-tests.sh [--scenario|-s <scenario>] container
#
#     Start container and start a shell session with helper commands
#     for accessing the container.
#     A short command documentation is printed at the start of the session.
#     The container is destroyed after exiting the shell.
#     An existing container is destroyed before starting.
#
#     Supported arguments:
#
#       --destroy|-d to destroy
#
#         When `run-tests.sh container` from inside an existing shell session,
#         the current container is updated without restarting by switching
#         its NixOS configuration.
#         Use this arg to destroy and restart the container instead.
#
#       --no-destroy|-n
#
#         By default, all commands destroy an existing container before starting and,
#         when appropriate, before exiting.
#         This ensures that containers start with no leftover filesystem state from
#         previous runs and that containers don't consume system resources after use.
#         This args disables auto-destructing containers.
#
#
#   run-tests.sh container --run c systemctl status bitcoind
#
#     Run a command in the shell session environmentand exit.
#     Destroy the container afterwards.
#     All arguments following `--run` are used as a command.
#     Supports argument '--no-destroy|-n' (see above for an explanation).
#
#     Example: Start shell inside container
#     run-tests.sh container --run c
#
#
#   run-tests.sh [--scenario|-s <scenario>] container --command|-c
#
#     Provide a custom extra-container command.
#
#     Example:
#       run-tests.sh container --command create -s
#       Create and start a container without a shell.
#
#
#   All extra args are passed to extra-container (unless --command is used):
#   run-tests.sh container --build-args --builders 'ssh://worker - - 8'

set -euo pipefail

if [[ $EUID != 0 ]]; then
    # NixOS containers require root permissions.
    # By using sudo here and not at the user's call-site extra-container can detect if it is running
    # inside an existing shell session (by checking an internal environment variable).
    #
    # shellcheck disable=SC2154
    exec sudo scenario="$scenario" scriptDir="$scriptDir" NIX_PATH="$NIX_PATH" PATH="$PATH" \
         scenarioOverridesFile="${scenarioOverridesFile:-}" "$scriptDir/lib/make-container.sh" "$@"
fi

export containerName=nb-test
containerCommand=shell

while [[ $# -gt 0 ]]; do
    case $1 in
        --command|-c)
            shift
            containerCommand=$1
            shift
            ;;
        *)
            break
    esac
done

containerBin=$(type -P extra-container) || true
if [[ ! ($containerBin && $(realpath "$containerBin") == *extra-container-0.10*) ]]; then
    echo "Building extra-container. Skip this step by adding extra-container 0.10 to PATH."
    nix-build --out-link /tmp/extra-container "$scriptDir"/../pkgs \
      -A pinned.extra-container >/dev/null
    export PATH="/tmp/extra-container/bin${PATH:+:}$PATH"
fi

read -rd '' src <<EOF || true
((import "$scriptDir/tests.nix" {}).getTest "$scenario").container
EOF
exec extra-container "$containerCommand" -E "$src" "$@"
