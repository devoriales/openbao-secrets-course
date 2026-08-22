# CAP03 justification

**Fill this in before you write any manifests.** The manifests are the easy part
and you have already built all three mechanisms in Module 5. The assessment is
whether you can say why each service gets the mechanism it gets, and what you
accepted when you chose it.

One section per service. Keep the answers to a few sentences each: this is a
design note, not an essay.

---

## Microservice A: reads dynamic database credentials

**Mechanism chosen:**

**Where does the secret materialise?**
> Name the exact location and the exact medium. "In the pod" is not an answer.

**Who else can read it there?**
> Think about who can exec, who can read the API object if there is one, and what
> a node compromise would expose.

**What happens when the credential rotates?**
> Does the file change, the environment variable change, neither? Does the
> application notice? What restarts, and how long is the gap?

**What happens when OpenBao is unreachable at pod start?**

**Why this mechanism for this service?**
> Reference the dimensions from lesson 5.1: how fast the secret rotates, who else
> can read it, whether the application can react to expiry, and what it costs the
> platform team.

**What you accepted by choosing it:**

---

## Microservice B: reads a third party API key

**Mechanism chosen:**

**Where does the secret materialise?**

**Who else can read it there?**
> This one has a longer answer than the others. Include anything that has ever
> taken a backup.

**What happens when the credential rotates?**
> Be precise about the three clocks from lesson 5.4, and about which of them your
> application actually observes.

**What happens when OpenBao is unreachable?**
> Distinguish "at first sync" from "after the secret already exists".

**Why this mechanism for this service, and why it would be wrong for
Microservice A's credential:**

**What you accepted by choosing it:**

---

## Microservice C: reads dynamic database credentials and manages its own lease

**Mechanism chosen:**

**Where does the secret materialise?**

**Who else can read it there?**

**What happens when the lease reaches its maximum TTL?**
> Not the token. The credential's own lease. Say what your code does at that
> moment, and what happens if it does nothing.

**What does this service do that the other two cannot?**

**Why this mechanism for this service:**

**What you accepted by choosing it:**
> Include the organisational cost, not just the technical one.

---

## The comparison

Fill this in last, from your own three answers rather than from the lesson.

| | A, sidecar | B, ESO | C, direct SDK |
|---|---|---|---|
| Materialises where | | | |
| Readable by | | | |
| Survives a rotation how | | | |
| Fails how, when OpenBao is down | | | |
| Cost to the application | | | |
| Cost to the platform | | | |

**The question to answer in one sentence:** if you had to run all three services
with a single mechanism, which would you pick, and which service would you have
to change to make that work?
