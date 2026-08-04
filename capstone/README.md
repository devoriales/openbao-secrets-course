# Capstone — Production-Hardened Cloud-Native Application Stack

The capstone for [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

**This folder contains task instructions, not a solved version.** That is deliberate. Working
out why a policy denies a request, or why a service keeps its database connection after you
revoked the lease, is the point of the exercise. A reference solution here would let you read
the answer instead of finding it, and you would arrive at the seal outage drill without having
built the intuition it tests.

## The five stages

| Stage | What you build |
|---|---|
| **CAP01** | Cluster and OpenBao deployment: HA on Raft, TLS everywhere, Transit auto-unseal, recovery keys handled per runbook |
| **CAP02** | Database and PKI integration: dynamic PostgreSQL credentials, certificates issued through cert-manager, `rotate-root` executed and verified |
| **CAP03** | Workload security: three microservices, one per consumption pattern (Agent sidecar, External Secrets Operator, AppRole with a Go `LifetimeWatcher`), each choice justified against the Lesson 5.1 decision matrix |
| **CAP04** | Hardening and auditing: file audit device, least-privilege HCL, a simulated lease revocation whose effect you verify is immediate across all three services |
| **CAP05** | Seal outage drill: kill the seal backend mid-demo, restart a production node, watch it fail, run the recovery runbook, and demonstrate that recovery keys alone cannot unseal the instance |

CAP05 is not optional. Recovering a sealed cluster under time pressure is the skill the whole
course is aimed at, and the difference between recovery keys and unseal keys is the single most
commonly misunderstood thing about running OpenBao.

## Layout

```
capstone/
  manifests/      Kubernetes manifests you apply
  helm-values/    Helm values files for the OpenBao and supporting charts
```

## Before you start

Have the pinned toolchain from [`VERSIONS.md`](../VERSIONS.md) installed, and a k3d cluster with
enough headroom for an HA OpenBao cluster, a second OpenBao acting as the Transit unsealer,
PostgreSQL, and MinIO running at the same time. Check the Docker VM's disk before you begin, not
after pods start getting evicted:

```bash
docker system df
```
