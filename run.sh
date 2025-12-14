#!/bin/bash

set -u

ARCH=$(uname -m)
ARCH_TYPE=""
EXECUTABLE_NAME=""
PIPE_FILE="/tmp/mta_input_$$"
SERVER_PID=""
SERVER_STOP_DELAY="${SERVER_STOP_DELAY:-10}"
STDIN_ACTIVE=true

get_architecture() {
    case "$ARCH" in
        "x86_64")
            ARCH_TYPE="_x64"
            ;;
        "aarch64")
            ARCH_TYPE="_arm64"
            ;;
        *)
            echo "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
}

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

create_pipe() {
    [ -e "$PIPE_FILE" ] && rm -f "$PIPE_FILE"
    mkfifo "$PIPE_FILE" || {
        echo "Failed to create named pipe: $PIPE_FILE"
        exit 1
    }
}

cleanup_pipe() {
    exec 3>&- 2>/dev/null || true
    [ -e "$PIPE_FILE" ] && rm -f "$PIPE_FILE"
}

save_databases() {
    echo "Saving databases.."

    mkdir -p shared-databases

    # Save internal.db and registry.db to shared-databases
    for file in internal.db registry.db; do
        if [ -f "multitheftauto_linux${ARCH_TYPE}/mods/deathmatch/${file}" ]; then
            cp -f "multitheftauto_linux${ARCH_TYPE}/mods/deathmatch/${file}" shared-databases/
        fi
    done

    # Save 'databases' directory to shared-databases
    if [ -d "multitheftauto_linux${ARCH_TYPE}/mods/deathmatch/databases" ]; then
        cp -rf "multitheftauto_linux${ARCH_TYPE}/mods/deathmatch/databases" shared-databases/
    fi
}

graceful_shutdown() {
    echo "Shutting down..."

    # Send shutdown command to server via pipe
    echo "shutdown" >&3 2>/dev/null || true

    # Wait for server to exit gracefully
    local elapsed=0
    while [ "$elapsed" -lt "$SERVER_STOP_DELAY" ] && kill -0 "$SERVER_PID" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
    done

    # Force kill server if still running
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        sleep 1
        kill -KILL "$SERVER_PID" 2>/dev/null || true
    fi

    # Exit triggers cleanup_and_save via EXIT trap
    exit 0
}

cleanup_and_save() {
    cleanup_pipe
    save_databases
}

server_is_running() {
    [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null
}

# Forward STDIN to the server via the named pipe
# Handles EOF gracefully to avoid busy-wait CPU spin
forward_stdin() {
    local line read_status

    while server_is_running; do
        # If STDIN was closed (EOF), just wait for server to exit
        if [ "$STDIN_ACTIVE" = false ]; then
            sleep 1
            continue
        fi

        # Read with timeout
        # Exit codes: 0 = success, 1 = EOF, >128 = timeout
        read -r -t 1 line
        read_status=$?

        if [ "$read_status" -eq 0 ]; then
            # Successfully read a line, forward it to server
            echo "$line" >&3 2>/dev/null || true

            # Exit loop on shutdown commands (server will handle them)
            case "$line" in
                shutdown|quit|exit) break ;;
            esac
        elif [ "$read_status" -gt 128 ]; then
            # Timeout - normal, continue waiting for input
            continue
        else
            # EOF or error (status 1) - stop reading
            STDIN_ACTIVE=false
        fi
    done
}

main() {
    get_architecture
    get_executable_name

    # Check if executable exists before creating pipe
    if [ ! -f "multitheftauto_linux${ARCH_TYPE}/${EXECUTABLE_NAME}" ]; then
        echo "ERROR: Executable not found: multitheftauto_linux${ARCH_TYPE}/${EXECUTABLE_NAME}"
        exit 1
    fi

    create_pipe
    trap graceful_shutdown SIGTERM SIGINT
    trap cleanup_and_save EXIT

    echo "Starting MTA:SA Server.."

    # Named pipes block on open until both ends are connected.
    # We need a writer before the server (reader) can start, but exec 3> blocks
    # until a reader exists. Solution: background a temporary writer to unblock
    # the server's read-open, then establish our persistent writer.

    # Start temporary pipe keeper (keeps pipe open for writing in background)
    { sleep infinity; } > "$PIPE_FILE" &
    PIPE_KEEPER_PID=$!

    # Start server with pipe as STDIN (won't block now since pipe has a writer)
    stdbuf -oL "multitheftauto_linux${ARCH_TYPE}/${EXECUTABLE_NAME}" -t -n -u < "$PIPE_FILE" &
    SERVER_PID=$!

    # Now open our persistent write handle (won't block since server is reading)
    exec 3>"$PIPE_FILE"

    # Kill the temporary pipe keeper - we have our own handle now
    kill "$PIPE_KEEPER_PID" 2>/dev/null || true
    wait "$PIPE_KEEPER_PID" 2>/dev/null || true

    # Verify server started successfully
    sleep 1
    if ! server_is_running; then
        echo "ERROR: Server process died immediately"
        exit 1
    fi

    # Forward STDIN to server until server exits or shutdown command
    forward_stdin

    # Wait for server to exit and capture exit code
    wait "$SERVER_PID" 2>/dev/null
    exit $?
}

main