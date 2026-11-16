# LuthiAI reviewer images

Ubuntu Noble images for LuthiAI's OpenShell reviewers, supporting `linux/amd64` and `linux/arm64`.
Each image includes `ca-certificates`, `git`, `gh`, and the upstream agent CLI.

| Image | CLI version |
| --- | --- |
| `ghcr.io/luthiai/review-claude` | Claude Code 2.1.325 |
| `ghcr.io/luthiai/review-codex` | Codex 0.169.0 |

## Downloads

Choose a version from [GitHub releases](https://github.com/luthiai/review-images/releases).
Download the rootfs tar and matching metadata for your agent and host architecture, for example:

```text
review-claude-linux-arm64.tar
review-claude-linux-arm64.tar.config.json
```

Keep the pair from the same release and verify both files using its `SHA256SUMS`.
See LuthiAI's [configuration guide](https://github.com/luthiai/luthiai/blob/main/skills/luthiai/references/configuration.md#vm-images-and-policies)
for setup instructions.
Each release also includes `release-manifest.json` with versions and image digests.

For container pulls, use a release tag or image digest from GHCR.
`latest` follows the last successful release.

## Releases

1. Update the CLI versions, architecture checksums, and Ubuntu base digest in the Containerfiles under `images/`.
2. Open a PR, pass the [checks workflow](.github/workflows/checks.yml), and merge to the default branch.
3. Push a new tag such as `images-2026.11.16.1` pointing to the merged commit.

The [release workflow](.github/workflows/images.yml) builds both architectures, runs smoke checks,
and publishes the GHCR images and GitHub release downloads.
Existing releases and fixed image tags are never overwritten.
To retry under a new tag after images were pushed, use a new commit too.

The Apache-2.0 license covers this repository's source.
Distributed packages and CLIs retain their own licenses.
