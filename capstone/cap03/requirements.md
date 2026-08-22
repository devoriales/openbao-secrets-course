# CAP03 acceptance criteria

The first one is the assessment. The rest are the evidence that you understood
what you wrote in it.

| # | Criterion | How you check it |
|---|---|---|
| 1 | `justification-template.md` is filled in, before the manifests were written | You have three sections and a filled comparison table, and none of the answers is "because the lesson used it" |
| 2 | Microservice A runs with an injected sidecar | The pod is `2/2` with `vault-agent-init` and `vault-agent` alongside your container |
| 3 | A's credential is a real dynamic one | The rendered file holds a `v-` prefixed username that appears in PostgreSQL's `pg_roles` |
| 4 | A actually queries the database with it, over verified TLS | Its log shows query results, not `certificate verify failed` |
| 5 | A's credential never becomes an API object | `kubectl -n payments get secret` shows nothing holding it, and `df` inside the pod shows `/vault/secrets` on tmpfs |
| 6 | Microservice B gets its API key through ESO | The `ExternalSecret` is `SecretSynced`, and the Secret it created exists |
| 7 | B consumes it as a mounted volume rather than an environment variable | Its Deployment mounts the Secret. Lesson 5.4 measured why: the environment copy never changes |
| 8 | Microservice C authenticates with AppRole and holds nothing on disk | Its log shows a login and a credential, and there is no Secret and no mounted file anywhere |
| 9 | C renews the **database lease**, not just the token | Its log shows lease renewals with a shrinking TTL as the role's `max_ttl` approaches |
| 10 | C handles the end of the lease deliberately | When the lease can no longer be renewed, the log says what it does next, and it is not "carry on" |
| 11 | Each service holds only what it needs | Three policies, each granting one path. C's is the only one that also needs `sys/leases/renew` |
| 12 | You can name where each credential lives, without looking it up | Say it out loud: tmpfs, etcd, process memory |

## The comparison you should be able to make afterwards

All three services now read a secret from the same OpenBao. One of them holds it
on a tmpfs that disappears with the pod, one holds it in etcd where anyone with
`get secrets` in the namespace can read it, and one holds it only in memory and
knows when it expires.

That is not three ways of doing the same thing. It is three different blast
radii, and CAP04 is where you find out which of them your audit log can tell
apart.
