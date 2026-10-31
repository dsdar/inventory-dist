# Home Inventory: distribution

Public downloads for the Home Inventory system: the installer, provisioning bundles, release manifests and update channels. Raspberry Pis download from here with **no account or token**.

**Do not edit by hand.** Everything except this README, `index.html` and `.nojekyll` is published by the release workflow in the (private) source repository. Published releases are never changed; fixes ship as new versions.

## Install on a fresh Raspberry Pi

On a Pi running Raspberry Pi OS Lite (64-bit):

```bash
curl -fsSL https://dsdar.github.io/inventory-dist/install.sh | sudo bash
```

To try pre-releases: `... | sudo bash -s -- --channel beta`

## Layout (served by GitHub Pages)

```
install.sh                    installer: picks a release from a channel, verifies it, runs its bootstrap
channel-stable.json           latest stable releases + minimum secure/supported versions
channel-beta.json             same, including pre-releases
infra/<version>/
    manifest.json             release manifest (what's in the release, checksums, image digests)
    bootstrap.sh
    ansible-bundle.tar.gz
app/<version>/
    manifest.json             application release manifest (images are on ghcr.io)
```

Container images are published separately on `ghcr.io/dsdar/inventory/*`.

Formats are defined in the source repository's `contract/release-manifest.md`.
