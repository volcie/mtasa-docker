#!/bin/bash

ARCH=$(uname -m)
EXECUTABLE_NAME=""

get_executable_name() {
    case "$ARCH" in
        "x86_64")
            EXECUTABLE_NAME="mta-server64"
            ;;
        "aarch64")
            EXECUTABLE_NAME="mta-server-arm64"
            ;;
        *)
            echo "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
}

main() {
    get_executable_name
    echo "Starting MTA:SA Server.."
    exec "server/${EXECUTABLE_NAME}" -n -u
}

main
