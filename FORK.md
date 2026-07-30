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

Note on naming: the add-on's **slug is `bitwarden`**, not `vaultwarden` — a
legacy name upstream never changed. The display name is "Vaultwarden" but the
container and data directory are `<repo_hash>_bitwarden`. There is no separate
Bitwarden add-on.

Take a full Home Assistant backup first.

1. Add this repository and install "Vaultwarden (dig)", but **do not start it**.
   Supervisor creates the data directory at install time — before that it does
   not exist, which is the usual reason people can't find it.

2. Open the *Advanced SSH & Web Terminal* add-on. Protection mode must be
   **off**, but note what that actually gets you: the Docker API, **not** the
   host filesystem. `/mnt/data/supervisor/...` is not mounted into that
   container and will appear missing. Reach host paths through a throwaway
   container instead — `docker run` bind mounts are resolved by the daemon on
   the host:

   ```sh
   docker run --rm -v /mnt/data/supervisor/addons/data:/d alpine ls -la /d | grep bitwarden
   ```

   On a Supervised (non-HA OS) install the base path is
   `/usr/share/hassio/addons/data`. To settle it authoritatively, ask Docker
   where the running add-on's `/data` actually lives:

   ```sh
   docker inspect addon_<old_hash>_bitwarden \
     --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
   ```

3. Stop the official Vaultwarden add-on. Copying a live SQLite database risks a
   torn read; stopped, the WAL is checkpointed cleanly.

4. Copy, preserving ownership and permissions:

   ```sh
   docker run --rm -v /mnt/data/supervisor/addons/data:/d alpine \
     sh -c 'cp -a /d/<old_hash>_bitwarden/. /d/<new_hash>_bitwarden/ && ls -la /d/<new_hash>_bitwarden'
   ```

   Copy the **whole directory**, not just `db.sqlite3` — leaving the `-wal`
   sidecar behind loses everything not yet checkpointed.

5. Copy your add-on options across (SSL, certfile, keyfile,
   `request_size_limit`) — those live in the add-on config, not `/data`. Watch
   the `ssl` default: this add-on ships `ssl: true`, so if your existing install
   has it off, set it off here too.

6. Start the fork. Confirm you can log in and see your vault **before**
   uninstalling the official add-on.

Both add-ons bind host port 7277, so only one can run at a time.

## Export/import instead?

Bitwarden's JSON export is a *vault items* export, not a backup, and it is the
lossy option. It omits file attachments entirely, along with Sends, trash,
emergency access contacts, organization items (each org exports separately), and
the RSA keypair — so every client has to log out and back in. TOTP secrets and
folders do survive; item revision dates reset.

The `/data` copy above has none of those gaps: it moves the server's actual
state, and clients never notice.

If you do export, the trap is the format. **"Account restricted" encrypted JSON
can only be imported back into the same account** — it's sealed with that
account's key and is useless for moving instances. Use **password-protected**
encrypted JSON, or plain `.json` (cleartext secrets on disk — shred it after).

Best practice: take a password-protected export as a *rollback artifact*, then
migrate by copying `/data`. The export is your safety net, not the mechanism.

## Going back to upstream

When upstream merges its backlog, uninstall this and reinstall the official
add-on — migrating `/data` back the same way. Nothing here changes the on-disk
data format.
