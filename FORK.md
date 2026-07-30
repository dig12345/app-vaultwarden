# Fork notes

## Why this exists

Upstream's build was wedged on stale Debian package pins — `libpq5` and `nginx`
versions that Debian had dropped from the trixie mirror — so every Renovate PR,
including the Vaultwarden 1.37.1 bump, failed CI and sat unmerged. The fix was
three lines. The wait was months.

This fork ships those three lines and automates the rest.

## What differs from upstream

| Change | Why |
| --- | --- |
| Debian packages unpinned | Stale pins are the failure mode being worked around |
| `repository.yaml` added | Makes this installable as a custom add-on repository |
| Upstream `ci.yaml` / `deploy.yaml` / label + stale bots removed | They call `hassio-addons` reusable workflows and org secrets |
| `renovate.json` removed | `nightly.yaml` supersedes it |
| `config.yaml`: real `version`, name `Vaultwarden (dig)` | Upstream ships `version: dev`; the name disambiguates in the HA UI |

The add-on itself — nginx config, s6 services, ingress glue — is untouched.

## How the nightly works

`.github/workflows/nightly.yaml`, 07:00 UTC:

1. **Merge upstream.** Conflicts under `.github/` resolve automatically in our
   favour (they're files we deleted). Anything else force-pushes an
   `upstream-sync` branch and opens a PR. Expect one when upstream eventually
   merges its own Vaultwarden bump and collides with ours in the Dockerfile.
2. **Check Docker Hub** for the newest bare `X.Y.Z` tag of `vaultwarden/server`.
   Prereleases, `latest`, `testing` and `-alpine` are ignored. Downgrades are
   refused.
3. **Build both arches.** Every night, whether or not anything changed — with
   the pins dropped, this is what catches Debian mirror drift.
4. **Push only if the build is green**, then tag `v<version>`. A red build opens
   an issue and pushes nothing, so the add-on stays on the last version that
   actually built.

Versioning: the add-on version tracks the Vaultwarden version exactly
(`1.37.1`). Upstream glue changes that don't move Vaultwarden get a build suffix
(`1.37.1-2`).

Run it on demand with `gh workflow run nightly.yaml` or the Actions tab.

## Installing

Settings → Add-ons → Add-on Store → ⋮ → Repositories → add:

```
https://github.com/dig12345/app-vaultwarden
```

"Vaultwarden (dig)" appears in the store. There is no prebuilt image, so
Supervisor builds it on the device — first install takes a few minutes.

## Migrating from the official add-on

**This matters: a fresh install starts with an empty vault.** Add-on data lives
in a per-instance `/data` volume — the SQLite database, the RSA keypair that
signs client tokens, and any attachments. A different add-on instance means a
different volume.

Take a full Home Assistant backup first.

1. Install "Vaultwarden (dig)" but **do not start it**.
2. Stop the official Vaultwarden add-on.
3. Shell into the host — the *Advanced SSH & Web Terminal* add-on with
   protection mode **off**, so `/mnt/data` is reachable.
4. Find both data directories:

   ```sh
   ls -d /mnt/data/supervisor/addons/data/*bitwarden*
   ```

   The official one is `<hash>_bitwarden`; this fork is a different `<hash>_bitwarden`.
   `ls -la` on each disambiguates — the official one has `db.sqlite3` and a
   recent mtime, the new one is empty or near-empty.

5. Copy, preserving ownership and permissions:

   ```sh
   cp -a /mnt/data/supervisor/addons/data/<old_hash>_bitwarden/. \
         /mnt/data/supervisor/addons/data/<new_hash>_bitwarden/
   ```

6. Copy your add-on options across in the UI (SSL, certfile, keyfile,
   `request_size_limit`) — those live in the add-on config, not `/data`.
7. Start the fork. Confirm you can log in and see your vault **before**
   uninstalling the official add-on.

Both add-ons bind host port 7277, so only one can run at a time.

## Going back to upstream

When upstream merges its backlog, uninstall this and reinstall the official
add-on — migrating `/data` back the same way. Nothing here changes the on-disk
data format.
