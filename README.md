# platform-ci

Shared GitHub Actions pipeline for every Spring Boot service on the Rezatron platform.
One implementation of the release lifecycle, called by each service repo, so a fix lands
once instead of three times.

Design rationale: [ADR 0002](https://github.com/rezatron-labs/rezatron-template) (runbook,
local-only) — GitFlow, release candidates, build-once/promote-many, and why the version
stays committed in the pom.

## What's here

| Reusable workflow | Purpose |
|---|---|
| `spring-ci.yml` | PR gate — `./mvnw verify`. No deploy, no tags. |
| `spring-publish.yml` | develop → **int**. Verify, build `sha-<commit>`, deploy. |
| `spring-release.yml` | Cut `release/$V`, move develop to the next `-SNAPSHOT`, build `v$V-rc.N` → **stage**. |
| `spring-hotfix.yml` | Cut `hotfix/$V` from `main`, then build candidates from the pushed fix → **stage**. |
| `spring-promote-prod.yml` | Re-tag the stage-validated candidate as `v$V`, deploy **prod**, back-merge, retire the branch. |
| `spring-rollback.yml` | Point an environment back at an older immutable tag. |
| `spring-deploy.yml` | The **one** writer of a gitops overlay. Never builds. |

| Action | Purpose |
|---|---|
| `actions/resolve-pom-merge` | Three-way-merges a `pom.xml` whose only real conflict is the project version. |

## Using it from a service

Each service repo keeps thin caller workflows that own the *trigger* and the *concurrency
group*; everything else lives here. A minimal set:

```yaml
# .github/workflows/publish.yml
name: publish
on:
  push:
    branches: [develop]
concurrency:
  group: myservice-int
  cancel-in-progress: true
jobs:
  publish:
    uses: rezatron-labs/platform-ci/.github/workflows/spring-publish.yml@v1
    with:
      service: myservice
    secrets: inherit
```

`service` is the only required input. It names both the image
(`nexus.home:8082/<service>:<tag>`) and the gitops overlay
(`<service>/<env>/override.yaml`) — which holds because the platform's naming convention
makes the repo, the image and the overlay directory one identity.

| Input | Default | When to set it |
|---|---|---|
| `service` | — | always |
| `java-version` | `21` | a service on a different JDK |
| `registry` | `nexus.home:8082` | — |
| `gitops-repo` | `rezatron-labs/platform-gitops` | — |
| `overlay-dir` | `<service>` | platform stacks that nest, e.g. `platform/config-server` |
| `verify-args` | *(empty)* | appended to `./mvnw -B verify` |
| `runner` | `["self-hosted","unraid"]` | a JSON array string |

`verify-args` exists because the self-hosted pool runs docker-in-docker, where Testcontainers
cannot start. A service with such tests passes `-DskipITs` here and runs the integration lane
as its own job on a hosted runner:

```yaml
jobs:
  verify:
    uses: rezatron-labs/platform-ci/.github/workflows/spring-ci.yml@v1
    with:
      verify-args: -DskipITs
  integration:
    runs-on: ubuntu-latest      # Testcontainers needs a real docker daemon
    steps: [...]
```

### Requirements

- `NEXUS_USER`, `NEXUS_PASS` and `GITOPS_DEPLOY_KEY` as **org** secrets, reaching the
  service repo. Callers pass them with `secrets: inherit`.
- `permissions: contents: write` on the **caller** for `release`, `hotfix` and
  `promote-prod`. A reusable workflow can never hold more permission than the workflow that
  called it, so granting it here is not optional — without it the branch, tag and back-merge
  pushes fail.
- The service builds its jar **inside** its Dockerfile; the workflows run `./mvnw verify`
  separately, on the same commit, before any image is built.
- `main` and `develop` branches, and a single-module `pom.xml` whose project `<version>`
  follows `</parent>`.
- `versions-maven-plugin` and `maven-help-plugin` pinned in the service's own
  `<pluginManagement>`. These workflows drive both by short prefix against the service's
  pom; unpinned, Maven resolves whatever is newest in Central at run time and how a release
  rewrites its version can change with no commit anywhere to explain it.
- Nothing — this repository is **public**, so any repo can call it. (Were it private,
  its Actions **Access** would have to be *"Accessible from repositories in the
  organization"*, which limits callers to this org.)

## Versioning

Callers pin `@v1`. That tag moves as fixes land, so one change reaches every service — which
is the point, and also the risk: a bad `v1` breaks the whole platform at once. Immutable
`v1.x.y` tags are cut alongside it, so a service can pin an exact version to hold back.

Because GitHub allows no variable in `uses:`, the internal references between these
workflows are literal `@v1`. **Cutting `v2` means updating those refs in the same commit** —
`self-test.yml` prints them on every run and fails if any points at a branch.

## Changing something

Land it on one service first. Nothing here has a staging environment of its own: `@v1`
moves and every service follows on its next run.
