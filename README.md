# wintosonos

This repository is intended to host the contents of:

- Source: `https://github.com/joaofo/artifacts/tree/main/sonos_redirector`
- Destination: `https://github.com/joaofo/wintosonos`

## Migration helper

Because outbound network access to GitHub is blocked in this environment (HTTP 403 from proxy),
I added a local helper script that can complete the migration as soon as GitHub access is available.

Run:

```bash
bash scripts/move_from_artifacts_sonos_redirector.sh
```

The script will:

1. Clone `joaofo/artifacts`
2. Copy `sonos_redirector/` contents into this repository root
3. Remove files not present in source
4. Preserve this repository `.git/`

Then commit and push from your machine/environment with GitHub connectivity.
