# CAP04 acceptance criteria

| # | Criterion | How you check it |
|---|---|---|
| 1 | Two audit devices are enabled through configuration | `bao audit list -detailed` shows both, and neither was enabled with `bao audit enable` because that returns 400 on 2.6.1 |
| 2 | The cluster was rolled without an unseal ceremony | You deleted three pods, in the right order, and typed no key material |
| 3 | The audit log records requests and responses | The file grows, and each line parses as JSON |
| 4 | Values are hashed, paths are not | Find an entry for a database credential read and confirm the username and password are `hmac-sha256:` while `request.path` is in clear |
| 5 | Each service has one policy, granting the paths it uses and nothing else | Three policies. Service C's is the only one with a second path, and you derived it from the audit log |
| 6 | A cross-service read is refused | Take service A's token, read service B's path, and get `permission denied` |
| 7 | You predicted the drill before running it | The predictions column of `observations-template.md` is filled in and dated before the results column |
| 8 | The drill was run against all three services at once | All three were live when you revoked |
| 9 | You can state, per service, when it stopped working and when it found out | Two different times for at least one service |
| 10 | You can attribute reads to identities | For each service, the `display_name` in the audit entries. One of them will not be the application |
| 11 | You can say what service C's watcher could and could not tell you | Specifically: whether it could distinguish revocation from the lease hitting its ceiling |
| 12 | `observations-template.md` is complete, including the last section | Two or three sentences on what you would change |

## The question this stage exists to answer

Your incident response plan probably contains the sentence "revoke the
credential". After this drill you know what that sentence does: it stops the
database accepting the credential immediately, and it leaves each of your
services to discover that in its own time and its own way.

Write down the longest of those times. That number is your real containment
window, and it is not the lease TTL.
