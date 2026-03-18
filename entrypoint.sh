#!/bin/bash
set -euo pipefail

BASE_URL="https://linux.multitheftauto.com/dl"
RESOURCES_URL="https://mirror.multitheftauto.com/mtasa/resources/mtasa-resources-latest.zip"
BASE_DIR="$PWD"

check_config() {
    echo "Checking config.."

    if [ ! "$(ls -A shared-config)" ]; then
        echo "Could not find base config, downloading.."

        wget -q "${BASE_URL}/baseconfig.tar.gz" -O /tmp/baseconfig.tar.gz \
        && tar -xzf /tmp/baseconfig.tar.gz -C /tmp \
        && mv /tmp/baseconfig/* shared-config \
        && rm -rf /tmp/baseconfig /tmp/baseconfig.tar.gz \
        || { echo "Failed to download or extract baseconfig"; exit 1; }
    fi

    # Symlink config files so host-level changes reflect inside the container immediately
    for file in shared-config/*; do
        if [ -f "${file}" ]; then
            fileName=$(basename "$file")
            target="server/mods/deathmatch/${fileName}"
            rm -f "${target}"
            ln -s "${BASE_DIR}/${file}" "${target}"
        fi
    done
}

link_modules() {
    echo "Linking modules.."

    local modules_dir
    case "$(uname -m)" in
        "x86_64")  modules_dir="server/x64/modules" ;;
        "aarch64") modules_dir="server/arm64/modules" ;;
        *)         echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac

    if [ ! -L "${modules_dir}" ]; then
        rm -rf "${modules_dir}"
        ln -s "${BASE_DIR}/shared-modules" "${modules_dir}"
    fi
}

install_resources() {
    if [ ! -L "${BASE_DIR}/server/mods/deathmatch/resources" ]; then
        ln -s "${BASE_DIR}/shared-resources" "${BASE_DIR}/server/mods/deathmatch/resources"
    fi

    if [[ "${INSTALL_DEFAULT_RESOURCES:-true}" != "false" ]]; then
        echo "INSTALL_DEFAULT_RESOURCES is not set to false, installing resources.."

        if [ ! "$(ls -A shared-resources)" ]; then
            echo "Downloading default resources.."

            wget -q "$RESOURCES_URL" -O /tmp/mtasa-resources.zip \
            && unzip -qo /tmp/mtasa-resources.zip -d shared-resources \
            && rm -f /tmp/mtasa-resources.zip \
            || { echo "Failed to download or unzip resources"; exit 1; }
        fi
    fi
}

setup_http_cache() {
    echo "Setting up HTTP cache.."

    mkdir -p "server/mods/deathmatch/resource-cache"
    chown mtasa:mtasa "server/mods/deathmatch/resource-cache"

    if [ ! -L "${BASE_DIR}/server/mods/deathmatch/resource-cache/http-client-files" ]; then
        ln -s "${BASE_DIR}/shared-http-cache" "${BASE_DIR}/server/mods/deathmatch/resource-cache/http-client-files"
    fi
}

link_databases() {
    echo "Linking databases.."

    mkdir -p "${BASE_DIR}/shared-databases/databases"

    # Symlink individual database files
    for file in internal.db registry.db; do
        local src="${BASE_DIR}/shared-databases/${file}"
        local target="server/mods/deathmatch/${file}"

        # Migrate existing regular file to shared volume if not already there
        if [ -f "${target}" ] && [ ! -L "${target}" ] && [ ! -f "${src}" ]; then
            mv "${target}" "${src}"
        fi

        rm -f "${target}"
        ln -s "${src}" "${target}"
    done

    # Migrate existing databases directory contents to shared volume
    if [ -d "server/mods/deathmatch/databases" ] && [ ! -L "server/mods/deathmatch/databases" ]; then
        if [ "$(ls -A server/mods/deathmatch/databases 2>/dev/null)" ]; then
            cp -rn server/mods/deathmatch/databases/* "${BASE_DIR}/shared-databases/databases/" 2>/dev/null || true
        fi
        rm -rf "server/mods/deathmatch/databases"
    fi

    if [ ! -L "server/mods/deathmatch/databases" ]; then
        ln -s "${BASE_DIR}/shared-databases/databases" "server/mods/deathmatch/databases"
    fi
}

main() {
    check_config
    link_modules
    install_resources
    setup_http_cache
    link_databases
}

main

# Fix volume ownership (entrypoint runs as root, drops to mtasa at the end)
find shared-config shared-modules shared-resources shared-http-cache shared-databases \
    \( ! -user mtasa -o ! -group mtasa \) -exec chown mtasa:mtasa {} +

exec gosu mtasa "$@"
