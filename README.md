# codemender-action

Run [Google CodeMender](https://docs.cloud.google.com/gemini-enterprise-agent-platform/agents/codemender) on every pull request with one short workflow file. CodeMender scans the code a pull request changes, fails the check on CRITICAL or HIGH findings, uploads results to GitHub code scanning, and opens a pull request with fixes.

This repository packages Google's [reference CI/CD workflow](https://docs.cloud.google.com/gemini-enterprise-agent-platform/agents/codemender/integrate-with-cicd) as:

- a **reusable workflow** (`.github/workflows/codemender.yml`) with the scan and autofix jobs, permissions and fork guard built in;
- a **composite action** (`eggboy/codemender-action`) that installs a pinned, checksum-verified CLI and runs the scan, for teams that want the step inside their own workflow;
- a **setup action** (`eggboy/codemender-action/setup`) that only installs the CLI;
- a **one-time Google Cloud setup script** (`scripts/setup-gcp.sh`) for Workload Identity Federation.

> [!IMPORTANT]
> CodeMender is a pre-GA product available to a limited set of customers. Its terms restrict use to testing and evaluation. In CI it runs with `--yes --bypass-warning`, which turns off the prompts that ask a person to confirm commands and file writes; enabling this action means you accept that, as described in Google's CI/CD guide.

## Setup

### 0. Preview access

CodeMender is available to a limited set of customers. Your Google Cloud project must be onboarded to the preview by your Google account team before any scan works. `cm health` does not test this: it passes on a project with the right IAM roles and no preview access. The only proof is a scan. After onboarding, run the **Preflight** workflow in this repository (Actions > Preflight > Run workflow); it scans a one-file project and fails with a clear message if the project isn't onboarded.

### 1. Google Cloud, once per project

Needs a project with CodeMender access and the `aiplatform.googleapis.com` API. Creates a service account with `roles/aiplatform.user`, a Workload Identity pool with a GitHub OIDC provider limited to your GitHub owner, and a binding for each repository. No keys are created.

```bash
PROJECT_ID=my-project GITHUB_OWNER=my-org REPOS="my-org/app my-org/api" ./scripts/setup-gcp.sh
```

The script prints three values. Add them as Actions secrets on each repository (or once at the organization level):

| Secret | Value |
|---|---|
| `GCP_PROJECT_ID` | Project ID |
| `GCP_WIF_PROVIDER` | `projects/NUMBER/locations/global/workloadIdentityPools/github/providers/github-actions` |
| `GCP_WIF_SERVICE_ACCOUNT` | `codemender-ci@PROJECT_ID.iam.gserviceaccount.com` |

### 2. Repository settings

- **Settings > Actions > General > Workflow permissions**: tick *Allow GitHub Actions to create and approve pull requests* (needed for autofix; skip if you set `autofix: false`).
- On private repositories, SARIF upload needs GitHub Code Security. Without it set `upload-sarif: false`; findings still appear in the job summary.
- Optional: a ruleset on `main` that requires the `CodeMender scan` check.
- Optional: enable **Require code scanning results** for `CodeMender` in your `main` branch ruleset and pass `fail-check: false` to the reusable workflow. GitHub code scanning enforces the severity gate on pull requests, maintainers can dismiss false positives in the Security tab to unblock merges, and `CodeMender scan` catches setup or scan execution errors while exporting findings to autofix.

### 3. The workflow

```yaml
name: CodeMender
on:
  pull_request:
    branches: [main]
permissions: {}
jobs:
  codemender:
    uses: eggboy/codemender-action/.github/workflows/codemender.yml@<commit-sha> # vX.Y.Z
    permissions:
      contents: write
      pull-requests: write
      id-token: write
      security-events: write
      actions: read
    secrets:
      GCP_PROJECT_ID: ${{ secrets.GCP_PROJECT_ID }}
      GCP_WIF_PROVIDER: ${{ secrets.GCP_WIF_PROVIDER }}
      GCP_WIF_SERVICE_ACCOUNT: ${{ secrets.GCP_WIF_SERVICE_ACCOUNT }}
```

Pin `@<commit-sha> # vX.Y.Z` to a release commit of this repository (each GitHub release includes the exact snippet). The reusable workflow reads its own commit from the OIDC token (`job_workflow_sha`) and checks out the action scripts at that commit, so the workflow and the scripts always move together. Configure Dependabot with `package-ecosystem: "github-actions"` in `.github/dependabot.yml` to receive automatic hash-pinned update pull requests when new `v<version>` releases are published.

## What happens on a pull request

1. **Scan.** Checkout with full history, keyless auth to Google Cloud, install the pinned CLI, `cm health --strict`, `cm init`, then `cm find . --diff=origin/<base>`. CodeMender scans the changed files plus the files that depend on them, and labels pre-existing findings `[LEGACY / UNTOUCHED]`. The job fails when a finding introduced by the pull request matches `fail-on`.
2. **Report.** The findings table lands in the job summary. The SARIF report goes to code scanning under the `codemender` category.
3. **Autofix.** When the scan fails, a second job runs `cm fix` for each blocking finding, commits each fix separately, and opens `codemender/fix-pr-<number>` into the pull request branch. GitHub doesn't run workflows on pull requests opened with `GITHUB_TOKEN`, so a maintainer clicks *Approve workflows to run* on the fix pull request. Merging it updates the original pull request, which is scanned again.

Fork and Dependabot pull requests skip the scan: their workflows can't read secrets, and pull request text can try to steer the agent. GitHub reports a skipped job as successful, so review those by hand.

## Reusable workflow inputs

| Input | Default | Meaning |
|---|---|---|
| `fail-on` | `CRITICAL,HIGH` | Severities that fail the check. `""` reports only and disables autofix. |
| `fail-check` | `true` | Fail the `CodeMender scan` check when findings match `fail-on`. Set to `false` when a GitHub code scanning ruleset enforces merge protection. |
| `cm-version` | `0.22.0` | CLI version. Must have a file in `checksums/`. |
| `upload-sarif` | `true` | Upload to code scanning. |
| `autofix` | `true` | Open a fix pull request when the scan fails. |
| `runs-on` | `ubuntu-24.04` | Runner label. Use GitHub-hosted runners: each job gets a fresh VM and the agent runs without its sandbox. |

## Composite action

For use inside your own job, after `actions/checkout` (`fetch-depth: 0`) and `google-github-actions/auth` (with `project_id`):

```yaml
- uses: eggboy/codemender-action@<commit-sha>
  id: scan
  with:
    fail-on: CRITICAL,HIGH
```

| Input | Default | Meaning |
|---|---|---|
| `version` / `sha256` | `0.22.0` / from `checksums/` | CLI version and expected checksum. |
| `base-ref` | `origin/${{ github.base_ref }}` | Ref to diff against. |
| `fail-on` | `CRITICAL,HIGH` | Severities that fail the step. |
| `diff-workers` | `16` | Files scanned concurrently. |
| `sarif-file` | `codemender.sarif` | SARIF output path. |
| `findings-file` | `$RUNNER_TEMP/codemender-findings.json` | JSON list of blocking findings, for autofix. |
| `summary` | `true` | Write the report to the job summary. |
| `fail` | `true` | Fail the step on blocking findings. |

Outputs: `status` (cm find exit code), `findings` (count of blocking findings), `sarif-file`.

## Supply chain notes

- The CLI is downloaded by exact version from Artifact Registry and verified against `checksums/<version>.sha256`. Google's sample fetches `stable`, which moves about weekly.
- Every third-party action is pinned to a commit SHA with the version in a comment.
- `.github/workflows/update-cm.yml` checks Artifact Registry daily for new `X.Y.Z` CLI versions, runs `./scripts/bump-version.sh <version>` to write `checksums/<version>.sha256` and update `CM_VERSION` and this README, verifies the binary with `cm health --strict` and a live `cm find` scan, and opens a pull request.
- Merging a `CM_VERSION` change to `main` triggers `.github/workflows/release.yml`, which cuts release `v<version>` at that commit with `checksums/<version>.sha256` attached. Enable immutable releases and tag protection rulesets on `v*` so published releases cannot move. Consumer repositories that pin `@<commit-sha> # v<version>` with Dependabot (`package-ecosystem: "github-actions"`) receive automatic hash-pinned update pull requests.
- `cm` runs with `--sandbox=false` in CI, as in Google's sample, because the Linux sandbox needs user namespaces that GitHub's runners don't provide. Whatever the agent executes has the job's credentials, which is why the service account holds `roles/aiplatform.user` and nothing else, and why you should not use self-hosted runners that are reused between jobs.

## Troubleshooting

The scan step prints a `CodeMender error details` group whenever `cm find` exits with anything other than 0 (clean) or 1 (findings). Read that group first.

| Log says | Meaning | Fix |
|---|---|---|
| `Unsupported agent interaction: codemender-preview` / "Access to the CodeMender preview release must be coordinated" | The project is not onboarded to the CodeMender preview. IAM is fine; `cm health` still passes | Ask your Google account team to onboard the project, then run the Preflight workflow |
| `cm health` exit 10 | No usable Google Cloud credential | Check the three secrets and that the job has `id-token: write` |
| `cm health` exit 40 | Service account lacks `roles/aiplatform.user`, or the API is disabled | Re-run `scripts/setup-gcp.sh` |
| `origin/<branch> is not in the checkout` | Shallow checkout | `actions/checkout` with `fetch-depth: 0` (the reusable workflow does this) |
| `Checksum mismatch` | Artifact Registry served a different binary than `checksums/<version>.sha256` records | Re-run `scripts/pin-version.sh <version>` and compare; treat an unexplained change as a supply-chain signal |
| Autofix job ran but no fix pull request | CodeMender fixed nothing, or Actions may not create pull requests | Check the job warnings; enable *Allow GitHub Actions to create and approve pull requests* |

## Cost

CodeMender is billed by tokens to the Google Cloud project. GitHub Actions minutes are billed as usual. The autofix job has a 60-minute timeout.

## License

Apache-2.0
