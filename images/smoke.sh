#!/usr/bin/env bash
# No credentials or model access: check OS, tools, adapter flags, and hold-command behavior.
set -euo pipefail

images_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fail() {
    echo "$*" >&2
    exit 1
}

[[ $# == 3 ]] || fail "Usage: $0 image-id claude|codex raw-config.json"

image=$1
agent=$2
config=$3

[[ $agent == claude || $agent == codex ]]
jq -e --arg agent "$agent" --arg arch "$(podman info --format '{{.Host.Arch}}')" \
    -f "$images_dir/config.jq" "$config" >/dev/null

version=$(jq -r '.config.Labels["org.opencontainers.image.version"]' "$config")
executable=/usr/local/bin/$agent
run=(podman run --rm --pull=never --network=none "$image")

# These variables are expanded inside the container.
# shellcheck disable=SC2016
"${run[@]}" /bin/sh -ec '
    . /etc/os-release
    test "$ID" = ubuntu && test "$VERSION_CODENAME" = noble && test "$PWD" = /sandbox

    for package in ca-certificates git gh; do
        test "$(dpkg-query -W -f="\${Status}" "$package")" = "install ok installed"
    done

    git --version
    gh --version
    test ! -e /usr/bin/curl
    test -z "$(find /var/lib/apt/lists -type f -print -quit)"
'

actual=$("${run[@]}" "$executable" --version)
printf '%s\n' "$actual"
[[ " $actual " == *" $version "* ]] || fail "Incorrect $agent version"

if [[ $agent == claude ]]; then
    help=$("${run[@]}" "$executable" --help)

    flags=(--bare --safe-mode --disable-slash-commands --strict-mcp-config --setting-sources
        --no-session-persistence --permission-mode --tools --allowedTools --model --output-format
        --json-schema --verbose --include-partial-messages --print)

    # The file form of the system-prompt flag is accepted but hidden from help.
    "${run[@]}" "$executable" --bare --safe-mode --disable-slash-commands --strict-mcp-config \
        --setting-sources '' --no-session-persistence --permission-mode dontAsk --tools Read,Bash \
        --allowedTools 'Read(./src/**)' --model smoke-check --append-system-prompt-file /dev/null \
        --output-format stream-json --json-schema '{"type":"object"}' --verbose \
        --include-partial-messages --print --help >/dev/null
else
    "${run[@]}" /bin/sh -ec '
        test -x /usr/local/bin/codex-code-mode-host
        test -x /usr/local/bin/codex-exec-server
        /usr/local/codex-path/rg --version
    '

    help=$("${run[@]}" "$executable" exec --help)

    flags=(--config --strict-config --ignore-user-config --ignore-rules --ephemeral --skip-git-repo-check
        --sandbox --cd --model --json --color --output-schema)
fi

for flag in "${flags[@]}"; do
    [[ $help == *"$flag"* ]] || fail "Adapter flag missing from $agent help: $flag"
done

container=$(podman run --detach --pull=never --network=none --env CODEX_HOME=/sandbox/output \
    --env CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 "$image" /bin/sh -c 'exec sleep infinity')
trap 'podman rm --force "$container" >/dev/null' EXIT

podman exec "$container" /bin/sh -ec '
    test "$PWD" = /sandbox
    test "$CODEX_HOME" = /sandbox/output
    test "$CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY" = 1
    test "$(printenv "$1")" = "$2"
' smoke "$(if [[ $agent == claude ]]; then echo CLAUDE_CODE_EXECUTABLE; else echo CODEX_PATH; fi)" "$executable"
