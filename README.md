# OpenBao Secrets Management — Lab Files

The companion repository for **[OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes)**
on devoriales.com.

> The lesson text, diagrams, knowledge checks, and explanations live on devoriales.com.
> **This repo is the runnable material** — Helm values, Kubernetes manifests, HCL policies,
> scripts, and sample application code. Every artifact here was executed end to end against
> a local k3d cluster before the lesson that references it was written. This repository is
> not a standalone tutorial; without the lessons it is a pile of YAML without the reasoning.

## What you build

One cluster, grown across five modules. A single sealed OpenBao instance becomes an HA Raft
cluster with TLS everywhere, Transit auto-unseal, dynamic PostgreSQL credentials, PKI issuing
through cert-manager, and three microservices that consume secrets three different ways. The
capstone hardens that stack, then deliberately kills the seal backend so you can practise the
recovery before you have to do it for real.

## Prerequisites

| For | You need |
|---|---|
| Every lab | Docker Engine — Docker Desktop, [Colima](https://github.com/abiosoft/colima), or a native Linux install |
| Every lab | [k3d](https://k3d.io/) v5.9.0, kubectl v1.36.3, Helm **v3.21.3** |
| Every lab | The `bao` CLI on your host, not only inside the cluster |
| Module 5.2 and the capstone | Go 1.26.5 |

Working Kubernetes knowledge is assumed: pods, services, ServiceAccounts, Helm. No prior
OpenBao or Vault experience is needed.

**Helm 4 is not supported here.** Helm's current release is 4.x, but the OpenBao chart has no
Helm 4 test coverage upstream, so this course pins **3.21.3**. Install that version explicitly
rather than taking whatever your package manager calls latest.

**Watch the Docker VM's disk, not your host's.** k3d nodes share the container runtime's
virtual disk, and kubelet evicts pods on `ephemeral-storage` pressure long before that disk is
full. A two node cluster running only cert-manager, External Secrets Operator, and a single
OpenBao evicted pods with 66 GiB still free on the host, because the Docker VM's 19 GB disk was
at 90%. Check with `docker system df` and `docker exec <node> df -h /`, reclaim with
`docker system prune`, and resize under Settings → Resources on Docker Desktop.

Every version this course was validated against is in [`VERSIONS.md`](VERSIONS.md).

## Setting up the cluster

k3d 5.9.0 defaults to a different k3s than the one this course pins, so always pass `--image`:

```bash
k3d cluster create openbao \
  --image rancher/k3s:v1.36.2-k3s1 \
  --servers 1 --agents 2 \
  --wait
```

Individual lessons extend this cluster or replace it; each lesson folder's `README.md` says
which, along with its own apply and cleanup steps.

## How to use this repo

Folders mirror the course 1:1, so you can navigate by lesson number:

```
module-1-architecture-first-deployment/
  lesson-1.2-k3d-setup/
  lesson-1.3-standalone-helm-tls/
  lesson-1.4-kv-v2/
module-2-auth-tokens-policy/          lesson-2.1 … lesson-2.5
module-3-seals-kms-day2-ops/          lesson-3.2 … lesson-3.8
module-4-secrets-engines/             lesson-4.1 … lesson-4.4
module-5-kubernetes-gitops-secops/    lesson-5.2 … lesson-5.6
capstone/
  manifests/
  helm-values/
```

Lessons 1.1, 3.1, and 5.1 have no folder here. They are the three that teach concepts rather
than run anything: barrier encryption, seal architecture, and the consumption decision matrix.

The capstone ships **task instructions only**. There is no solved version in this repository,
by design.

## Release tagging policy

Tags are named for the OpenBao release the artifacts were validated against:

```
v1.0-openbao-2.6.1
```

When a re-validation pass moves the course to a newer OpenBao release, that cuts a **new** tag.
Existing tags are never overwritten or force-pushed, so a student partway through the course
does not have the ground shift under them. Check out the tag matching the version your lessons
reference:

```bash
git checkout v1.0-openbao-2.6.1
```

The current baseline is OpenBao **v2.6.1** with Helm chart **openbao-0.28.6**.

## License

[MIT](LICENSE).
