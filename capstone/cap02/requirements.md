# CAP02 acceptance criteria

Every one of these is a command whose output you read. Three of them are
deliberately arranged so that the obvious way to check them gives a false pass.

| # | Criterion | How you check it, and what to avoid |
|---|---|---|
| 1 | PostgreSQL is running with the seeded schema | `psql -c 'select count(*) from payments'` returns a row |
| 2 | The database engine is mounted and configured with an allowed role list | `bao read database/config/appdb` shows your role in `allowed_roles` |
| 3 | A dynamic credential can be issued | `bao read database/creds/payments-ro` returns a lease, a username beginning `v-`, and a password |
| 4 | That credential actually logs in | Connect **from a separate pod** over the service name. Connecting from inside `postgres-0` proves nothing: loopback is `trust` in the stock `pg_hba.conf`, and even a wrong password succeeds |
| 5 | The credential expires | Read its lease TTL, wait, and watch the login stop working. Or revoke the lease and watch the same thing happen immediately |
| 6 | `rotate-root` has been executed | `bao write -f database/rotate-root/appdb` returned success |
| 7 | The committed bootstrap password no longer works | From the client pod, over the service: `FATAL: password authentication failed for user "openbao_admin"`. From inside the database pod you will get a row back and learn nothing |
| 8 | OpenBao can still issue credentials afterwards | Issue another one and log in with it. Criterion 7 without this means you broke the engine rather than rotated it |
| 9 | OpenBao's PKI issues a certificate for the database | `kubectl -n databases get certificate postgres-tls` is `True`, and the certificate's issuer is your intermediate CA |
| 10 | PostgreSQL is serving that certificate | `show ssl;` returns `on`, and `pg_stat_ssl` for your own backend shows a TLS version and cipher |
| 11 | A client can verify the chain | `sslmode=verify-full` with `PGSSLROOTCERT` set to the OpenBao root succeeds; the same connection without the root fails and says so |
| 12 | Nothing in the repository still holds a working credential | The bootstrap password in the manifest is now historical. Say out loud what it would take an attacker with repository access to get in today |

## Questions you should be able to answer

- Why does `rotate-root` not break the `connection_url` in the engine config?
- Why is verifying a rotation from inside the database pod meaningless, and what
  does that tell you about how you would test this in production?
- What has to match between the cert-manager `Certificate` and the OpenBao PKI
  role, and what does the mismatch look like from each side?
- Which CA does cert-manager's `caBundle` refer to, and which one does it not?
