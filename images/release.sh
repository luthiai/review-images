#!/usr/bin/env bash
# CI orders these stages and grants each job only its required publication permission.
set -euo pipefail

mode=${1:-}
builds=${2:-build}
downloads=${3:-dist}
source_commit=${GITHUB_SHA:?}
version=${GITHUB_REF_NAME:?}
names=(review-{claude,codex}-linux-{amd64,arm64}.tar{,.config.json} release-manifest.json)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT

fail() {
    echo "$*" >&2
    exit 1
}

verify_checksums() (
    cd -- "$1"
    shift
    diff -u <(printf '%s\n' "$@" | LC_ALL=C sort) \
        <(awk '{print $2}' SHA256SUMS | LC_ALL=C sort)
    sha256sum --check SHA256SUMS
)

verify_build() {
    local directory=$builds/$1/$2 name=review-$1-linux-$2.tar

    verify_checksums "$directory" image.oci.tar build.json "$name" "$name.config.json"
    jq -e --arg agent "$1" --arg arch "$2" --arg source "$source_commit" '
        .agent == $agent and .architecture == $arch and .source_commit == $source
        and .validation.container_smoke == "passed"
        and (.image_digest | test("^sha256:[a-f0-9]{64}$"))
        and (.ubuntu_base_digest | test("^sha256:[a-f0-9]{64}$"))
        and (.cli_version | type == "string" and length > 0)
    ' "$directory/build.json" >/dev/null
}

check_sizes() {
    local name size

    for name in "${names[@]}" SHA256SUMS; do
        [[ -f $downloads/$name && ! -L $downloads/$name ]] || fail "Missing regular asset: $name"
        size=$(wc -c < "$downloads/$name")
        (( size > 0 && size < 2147483648 )) || fail "Asset must be nonempty and smaller than 2 GiB: $name"
    done
}

registry_login() {
    export REGISTRY_AUTH_FILE=$temporary/auth.json
    skopeo login --username "${GITHUB_ACTOR:?}" --password-stdin ghcr.io <<< "${GH_TOKEN:?}"
}

case "$mode" in
    prepare)
        mkdir -p -- "$downloads"
        [[ -z $(ls -A "$downloads") ]] || fail "Output directory must be empty: $downloads"

        for agent in claude codex; do
            for arch in amd64 arm64; do
                verify_build "$agent" "$arch"
                name=review-$agent-linux-$arch.tar
                cp "$builds/$agent/$arch/$name" "$builds/$agent/$arch/$name.config.json" "$downloads/"
            done
        done

        jq -s --arg version "$version" --arg source "$source_commit" '
            if ([.[].ubuntu_base_digest] | unique | length) != 1 then error("Ubuntu bases differ") else . end
            | {
                schema_version: 1, version: $version, source_commit: $source,
                ubuntu_base_digest: .[0].ubuntu_base_digest,
                agents: (group_by(.agent) | map(
                    if ([.[].cli_version] | unique | length) != 1 then error("CLI versions differ") else . end
                    | {key: .[0].agent, value: {
                        cli_version: .[0].cli_version,
                        image: ("ghcr.io/luthiai/review-" + .[0].agent),
                        architectures: (map({key: .architecture, value: .image_digest}) | from_entries)
                    }}
                ) | from_entries),
                validation: {
                    container_smoke: "passed on native amd64 and arm64",
                    openshell_live: "not run by CI; operator validation required"
                }
            }
        ' "$builds/claude/amd64/build.json" "$builds/claude/arm64/build.json" \
            "$builds/codex/amd64/build.json" "$builds/codex/arm64/build.json" > "$downloads/release-manifest.json"

        (cd -- "$downloads" && sha256sum "${names[@]}" > SHA256SUMS)
        verify_checksums "$downloads" "${names[@]}"
        check_sizes
        ;;
    registry)
        registry_login
        mkdir -p registry

        for agent in claude codex; do
            image=ghcr.io/luthiai/review-$agent

            for arch in amd64 arm64; do
                verify_build "$agent" "$arch"
                skopeo copy --preserve-digests "oci-archive:$builds/$agent/$arch/image.oci.tar" \
                    "docker://$image:$version-$arch"
            done

            amd64=$(jq -r '.image_digest' "$builds/$agent/amd64/build.json")
            arm64=$(jq -r '.image_digest' "$builds/$agent/arm64/build.json")
            list=localhost/review-$agent-$version-$$
            podman manifest create "$list" "docker://$image@$amd64" "docker://$image@$arm64"
            podman manifest push --all --format oci --rm --digestfile "$temporary/digest" \
                "$list" "docker://$image:$version"

            digest=$(cat "$temporary/digest")
            skopeo inspect --raw "docker://$image:$version" > "$temporary/index.json"
            [[ $(skopeo manifest-digest "$temporary/index.json") == "$digest" ]]
            jq -e --arg amd64 "$amd64" --arg arm64 "$arm64" '
                (.manifests | length) == 2 and all(.manifests[]; .platform.os == "linux")
                and (.manifests | map({key: .platform.architecture, value: .digest}) | from_entries)
                    == {amd64: $amd64, arm64: $arm64}
            ' "$temporary/index.json" >/dev/null

            skopeo copy --all --preserve-digests "docker://$image@$digest" "docker://$image:sha-$source_commit"
            jq -n --arg agent "$agent" --arg source "$source_commit" --arg version "$version" \
                --arg digest "$digest" --arg amd64 "$amd64" --arg arm64 "$arm64" '{
                agent: $agent, source_commit: $source, version: $version,
                index_digest: $digest, architectures: {amd64: $amd64, arm64: $arm64}
            }' > "registry/$agent.json"
        done
        ;;
    publish)
        verify_checksums "$downloads" "${names[@]}"

        for agent in claude codex; do
            jq -e --arg agent "$agent" --arg source "$source_commit" --arg version "$version" \
                --slurpfile receipt "registry/$agent.json" '
                $receipt[0] as $r |
                if .source_commit == $source and .version == $version
                    and $r.agent == $agent and $r.source_commit == $source and $r.version == $version
                    and $r.architectures == .agents[$agent].architectures
                    and ($r.index_digest | test("^sha256:[a-f0-9]{64}$"))
                then .agents[$agent].index_digest = $r.index_digest
                else error("Registry receipt differs from checked builds") end
            ' "$downloads/release-manifest.json" > "$temporary/manifest.json"

            mv "$temporary/manifest.json" "$downloads/release-manifest.json"
        done

        (cd -- "$downloads" && sha256sum "${names[@]}" > SHA256SUMS)
        check_sizes
        files=()

        for name in "${names[@]}" SHA256SUMS; do
            files+=("$downloads/$name")
        done

        {
            printf 'Reviewer images from %s.\n\n' "$source_commit"
            jq -r '.agents[] | "- \(.image)@\(.index_digest) (CLI \(.cli_version))"' "$downloads/release-manifest.json"
            printf '\nDownload the matching tar and .tar.config.json pair; verify SHA256SUMS.\n'
            printf '\nNative container smoke checks passed. Live OpenShell model tool execution needs a separate operator check.\n'
        } > "$temporary/notes.md"

        # This job has contents:write, so the release list includes drafts.
        gh api 'repos/luthiai/review-images/releases?per_page=100' --paginate > "$temporary/releases.json"

        jq -e -s --arg version "$version" 'all(.[][]; .tag_name != $version)' \
            "$temporary/releases.json" > /dev/null || fail 'Release already exists, including drafts. Use a new version.'

        gh release create "$version" --repo luthiai/review-images --draft --verify-tag \
            --target "$source_commit" --title "$version" --notes-file "$temporary/notes.md" "${files[@]}"
        release_api=$(gh release view "$version" --repo luthiai/review-images --json apiUrl --jq .apiUrl)
        gh api "$release_api" > "$temporary/release.json"
        jq -e --arg version "$version" '.tag_name == $version and .draft == true and (.assets | length) == 10' \
            "$temporary/release.json" >/dev/null

        for file in "${files[@]}"; do
            jq -e --arg name "${file##*/}" --arg digest "sha256:$(sha256sum "$file" | awk '{print $1}')" \
                --argjson size "$(wc -c < "$file" | tr -d '[:space:]')" '
                [.assets[] | select(.name == $name)] |
                length == 1 and .[0].state == "uploaded" and .[0].size == $size and .[0].digest == $digest
            ' "$temporary/release.json" >/dev/null || fail "Uploaded asset differs: $file"
        done

        gh api "$release_api" --method PATCH -F draft=false -f make_latest=true > "$temporary/release.json"
        jq -e '.draft == false' "$temporary/release.json" >/dev/null
        ;;
    latest)
        gh api "repos/luthiai/review-images/releases/tags/$version" | jq -e '.draft == false' >/dev/null
        registry_login

        for agent in claude codex; do
            image=ghcr.io/luthiai/review-$agent
            digest=$(jq -er --arg agent "$agent" --arg source "$source_commit" --arg version "$version" '
                select(.agent == $agent and .source_commit == $source and .version == $version)
                | .index_digest | select(test("^sha256:[a-f0-9]{64}$"))
            ' "registry/$agent.json")

            skopeo copy --all --preserve-digests "docker://$image@$digest" "docker://$image:latest"
            skopeo inspect --raw "docker://$image:latest" > "$temporary/index.json"
            [[ $(skopeo manifest-digest "$temporary/index.json") == "$digest" ]]
        done
        ;;
    *)
        fail "Usage: $0 prepare|registry|publish|latest [builds-directory downloads-directory]"
        ;;
esac
