#!/usr/bin/env bash
# Offline regression checks for artifact integrity, metadata, and publication gates.
set -euo pipefail

images_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_commit=$(git -C "$images_dir/.." rev-parse HEAD)
export GITHUB_SHA=$source_commit
export GITHUB_REF_NAME=images-2026.11.16.1
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT

expect_failure() {
    local description=$1
    shift

    if "$@" > "$temporary/failure.log" 2>&1; then
        echo "Unexpected success: $description" >&2
        exit 1
    fi

    printf 'Passed: %s\n' "$description"
}

for agent in claude codex; do
    for arch in amd64 arm64; do
        directory=$temporary/build/$agent/$arch
        name=review-$agent-linux-$arch.tar
        mkdir -p "$directory"
        printf 'checked OCI archive fixture\n' > "$directory/image.oci.tar"
        tar -cf "$directory/$name" -C "$directory" image.oci.tar

        jq -n --arg agent "$agent" --arg arch "$arch" '{
            os: "linux", architecture: $arch, rootfs: {type: "layers"},
            config: {Env: [(if $agent == "claude" then "CLAUDE_CODE_EXECUTABLE" else "CODEX_PATH" end)
                + "=/usr/local/bin/" + $agent], WorkingDir: "/sandbox", Cmd: ["/bin/bash"]}
        }' > "$directory/$name.config.json"

        jq -n --arg agent "$agent" --arg arch "$arch" --arg source "$source_commit" --arg digest "$digest" '{
            agent: $agent, architecture: $arch, source_commit: $source,
            image_digest: $digest, ubuntu_base_digest: $digest, cli_version: "fixture-version",
            validation: {container_smoke: "passed"}
        }' > "$directory/build.json"

        (cd -- "$directory" && sha256sum image.oci.tar build.json "$name" "$name.config.json" > SHA256SUMS)
    done
done

bash "$images_dir/release.sh" prepare "$temporary/build" "$temporary/dist" >/dev/null
printf 'Passed: complete four-build download set and checksums\n'

config=$temporary/build/codex/arm64/review-codex-linux-arm64.tar.config.json
config_check=(jq -e --arg agent codex --arg arch arm64 -f "$images_dir/config.jq")
"${config_check[@]}" "$config" >/dev/null

for filter in '[.]' '.config.Env += .config.Env' '.config.Env += ["CODEX_HOME=/root/.codex"]' '.architecture = "amd64"'; do
    jq "$filter" "$config" > "$temporary/bad.json"
    expect_failure "invalid OCI configuration: $filter" "${config_check[@]}" "$temporary/bad.json"
done

record=$temporary/build/codex/arm64/build.json
jq '.source_commit = "wrong"' "$record" > "$temporary/record.json"
cp "$record" "$temporary/original.json"
cp "$temporary/record.json" "$record"
(cd -- "${record%/*}" && sha256sum image.oci.tar build.json review-codex-linux-arm64.tar* > SHA256SUMS)
expect_failure 'source mismatch despite valid checksums' bash "$images_dir/release.sh" prepare "$temporary/build" "$temporary/bad-source"

cp "$temporary/original.json" "$record"
(cd -- "${record%/*}" && sha256sum image.oci.tar build.json review-codex-linux-arm64.tar* > SHA256SUMS)
cp "${record%/*}/SHA256SUMS" "$temporary/sums"
sed '$d' "$temporary/sums" > "${record%/*}/SHA256SUMS"
expect_failure 'incomplete checksum coverage' bash "$images_dir/release.sh" prepare "$temporary/build" "$temporary/incomplete"

cat "$temporary/sums" "$temporary/sums" > "${record%/*}/SHA256SUMS"
expect_failure 'duplicate checksum entries' bash "$images_dir/release.sh" prepare "$temporary/build" "$temporary/duplicates"

cp "$temporary/sums" "${record%/*}/SHA256SUMS"
printf 'tampered\n' >> "$temporary/build/codex/arm64/image.oci.tar"
expect_failure 'changed saved image' bash "$images_dir/release.sh" prepare "$temporary/build" "$temporary/tampered"

mkdir "$temporary/bin"

# Simulate GitHub uploads to exercise draft verification without external writes.
cat > "$temporary/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

not_found() {
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1
}

case "$1/$2" in
    api/*)
        case "${TEST_RELEASE:-}" in
            denied) echo 'gh: Forbidden (HTTP 403)' >&2; exit 1 ;;
            network) echo 'error connecting to api.github.com' >&2; exit 1 ;;
        esac

        if [[ ${TEST_RELEASE:-} == exists || ${TEST_RELEASE:-} == draft ]]; then
            draft=false
            [[ $TEST_RELEASE != draft ]] || draft=true
            record=$(jq -n --arg tag "$GITHUB_REF_NAME" --argjson draft "$draft" \
                '{id: 123, tag_name: $tag, draft: $draft, assets: []}')
        elif [[ -f release.json ]]; then
            record=$(cat release.json)
        else
            record=null
        fi

        case "$2" in
            */releases\?per_page=100)
                [[ ${3:-} == --paginate ]]
                # Put the matching release on a later page.
                jq -nc '[range(100) | {tag_name: ("older-" + tostring), draft: false}]'
                jq -n --argjson record "$record" 'if $record == null then [] else [$record] end'
                ;;
            */releases/tags/*)
                [[ $record != null && $(jq -r '.draft' <<< "$record") == false ]] || not_found
                printf '%s\n' "$record"
                ;;
            */releases/123)
                [[ $record != null ]] || not_found

                if [[ ${3:-} == --method ]]; then
                    [[ $4 == PATCH ]]
                    jq '.draft = false' <<< "$record" > release.json
                    touch published
                    cat release.json
                else
                    printf '%s\n' "$record"
                fi
                ;;
            *) exit 1 ;;
        esac
        ;;
    release/create)
        touch created
        for file in dist/*; do
            jq -n --arg name "${file##*/}" --arg digest "sha256:$(sha256sum "$file" | awk '{print $1}')" \
                --argjson size "$(wc -c < "$file")" '{name: $name, digest: $digest, size: $size, state: "uploaded"}'
        done | jq -s --arg tag "$GITHUB_REF_NAME" --arg bad "${TEST_BAD_DIGEST:-false}" '
            {id: 123, tag_name: $tag, draft: true, assets: .}
            | if $bad == "true" then .assets[0].digest = "wrong" else . end
        ' > release.json
        ;;
    release/view)
        [[ -f release.json ]]
        printf 'https://api.github.com/repos/luthiai/review-images/releases/123\n'
        ;;
    *) exit 1 ;;
esac
MOCK

chmod +x "$temporary/bin/gh"
mkdir "$temporary/registry"

for agent in claude codex; do
    jq --arg agent "$agent" --arg digest "$digest" '{
        agent: $agent, source_commit, version, index_digest: $digest, architectures: .agents[$agent].architectures
    }' "$temporary/dist/release-manifest.json" > "$temporary/registry/$agent.json"
done

release() (
    local mode=$1
    shift
    cd -- "$temporary"
    env "PATH=$temporary/bin:$PATH" "$@" bash "$images_dir/release.sh" "$mode"
)

for state in exists draft denied network; do
    expect_failure "publication release state: $state" release publish "TEST_RELEASE=$state"
    [[ ! -e $temporary/created ]]
done

for state in absent draft denied network; do
    expect_failure "latest release state: $state" release latest "TEST_RELEASE=$state"
done

expect_failure 'tag endpoint hides draft releases' env "PATH=$temporary/bin:$PATH" TEST_RELEASE=draft \
    gh api "repos/luthiai/review-images/releases/tags/$GITHUB_REF_NAME"

expect_failure 'uploaded digest mismatch blocks publication' release publish TEST_BAD_DIGEST=true
[[ ! -e $temporary/published ]]
cp "$temporary/release.json" "$temporary/original-draft.json"
expect_failure 'existing draft blocks publication on retry' release publish
cmp "$temporary/original-draft.json" "$temporary/release.json"
rm -- "$temporary/release.json"
release publish >/dev/null
[[ -f $temporary/published ]]
printf 'Passed: verified draft assets publish successfully\n'
