# artemis2 self-hosted GitHub Actions runner

The firefox-watch rebuild job runs here (Docker + local registry live on artemis2).

## Register (one-time)
1. GitHub → repo Settings → Actions → Runners → New self-hosted runner (Linux x64).
2. On artemis2, follow the shown `./config.sh --url … --token …`. Add labels: `self-hosted,artemis2`.
3. Install as a service: `sudo ./svc.sh install && sudo ./svc.sh start`.

## Security (public repo)
- Settings → Actions → General → "Fork pull request workflows": require approval for all outside
  collaborators; do NOT allow forks to run workflows.
- The rebuild job is additionally guarded with `if: github.event_name != 'pull_request'`.
- Keep the runner in a dedicated runner group restricted to this repo.

## Prereqs on artemis2 (already present)
- Docker (arm64 emulation), `oras`, local registry at 127.0.0.1:5001, `~/firecracker-mac` checkout,
  `git` push creds for the repo, Python 3.
