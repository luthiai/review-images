#!/usr/bin/env bash
# Build, smoke-test, and export one image on its native architecture.
set -euo pipefail

images_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fail() {
    echo "$*" >&2
    exit 1
}

[[ $# == 2 ]] || fail "Usage: $0 claude|codex amd64|arm64"
agent=$1
arch=$2

case "$agent/$arch" in
    claude/amd64|claude/arm64|codex/amd64|codex/arm64) ;;
    *) fail "Unsupported agent/architecture: $agent/$arch" ;;
esac

[[ $(podman info --format '{{.Host.Arch}}') == "$arch" ]] || fail 'Use the matching native architecture'
source_commit=$(git -C "$images_dir/.." rev-parse HEAD)
output=$images_dir/../build/$agent/$arch
mkdir -p -- "$output"
[[ -z $(ls -A "$output") ]] || fail "Output directory must be empty: $output"
output=$(cd -- "$output" && pwd)

temporary=$(mktemp -d)
container=

cleanup() {
    if [[ -n $container ]]; then
        podman rm --force "$container" >/dev/null
    fi

    rm -rf -- "$temporary"
}

trap cleanup EXIT

podman build --format oci --arch "$arch" \
    --label "org.opencontainers.image.revision=$source_commit" \
    --iidfile "$temporary/image-id" "$images_dir/$agent"

image=$(cat "$temporary/image-id")
name=review-$agent-linux-$arch.tar
config=$output/$name.config.json
podman save --format oci-archive --output "$output/image.oci.tar" "$image"
skopeo inspect --config --raw "oci-archive:$output/image.oci.tar" > "$config"
[[ sha256:$(sha256sum "$config" | awk '{print $1}') == "$image" ]]

bash "$images_dir/smoke.sh" "$image" "$agent" "$config"

# Export a fresh, unstarted container from the exact smoke-tested image.
container=$(podman create --pull=never "$image")
podman export --output "$output/$name" "$container"
podman rm "$container" >/dev/null
container=

tar -tf "$output/$name" | sed 's#^\./##; s#/$##' > "$temporary/members"

for member in sandbox usr/lib/os-release var/lib/dpkg/status "usr/local/bin/$agent"; do
    grep -Fxq "$member" "$temporary/members"
done

image_digest=$(skopeo inspect --format '{{.Digest}}' "oci-archive:$output/image.oci.tar")

jq -n --arg agent "$agent" --arg arch "$arch" --arg source "$source_commit" \
    --arg digest "$image_digest" --slurpfile config "$config" '{
    agent: $agent,
    architecture: $arch,
    source_commit: $source,
    image_digest: $digest,
    cli_version: $config[0].config.Labels["org.opencontainers.image.version"],
    ubuntu_base_digest: $config[0].config.Labels["org.opencontainers.image.base.digest"],
    validation: {container_smoke: "passed", openshell_live: "not run"}
}' > "$output/build.json"

(cd -- "$output" && sha256sum image.oci.tar build.json "$name" "$name.config.json" > SHA256SUMS)
printf 'Validated %s linux/%s: %s\n' "$agent" "$arch" "$image_digest"
