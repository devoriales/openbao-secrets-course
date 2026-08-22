# CAP01 — Cluster and OpenBao deployment

Build the thing everything else in the capstone runs on: a three node OpenBao
cluster on Raft, TLS on every listener, unsealing itself against a Transit key
held by a second, separate OpenBao.

None of that is new. Lesson 3.7 built Raft, 3.2 built Transit auto-unseal, 1.3
and 4.2 built TLS. What is new is running all three at once, and the three
problems that only exist where two of them meet.

## What you are building

Two OpenBao instances, in two namespaces, with two certificates and two trust
anchors.

The **unsealer** is small: Shamir sealed with three shares and a threshold of
two, on file storage, holding one Transit key called `autounseal` and nothing
else. A human unseals it by hand, and it is the only instance where that is
still true.

The **production cluster** is three nodes on Raft with TLS on every listener. It
never sees a Shamir share: its root key is wrapped by that Transit key, so it
unseals itself at every start, and `bao operator init` gives you recovery keys
rather than unseal keys.

The published lesson for this stage carries the topology diagram, and it is worth
looking at before you write any YAML: the interesting part is which certificate
each connection verifies, and there are three different answers.

## Files here

| File | What it is |
|---|---|
| `certificates.yaml.skeleton` | Two cert-manager Certificates. The SAN list on one of them is the exercise |
| `values-unsealer.yaml.skeleton` | The unsealer chart values |
| `values-production.yaml.skeleton` | The production chart values, with three THINK markers |
| `runbook-init.md` | The order of operations, and why `init` looks different here |
| `requirements.md` | Eleven acceptance criteria you can check yourself |
| `troubleshooting.md` | The four failures you are most likely to produce |

The skeletons name every key you need and leave the values blank. That is
deliberate: the shape of the file is not the hard part, and looking up which
value goes where is the work that makes the next stage possible.

## Order

1. Certificates first. Nothing starts cleanly without them, and the SAN list is
   easier to get right before three pods are arguing about it.
2. The unsealer, then its Shamir ceremony, then the Transit key, then the token
   and CA into the production namespace.
3. The production cluster. `init` with recovery shares, not key shares.
4. Verify all eleven criteria in `requirements.md`.
5. Produce the cold start failure on purpose and recover from it.

## The one thing to carry into CAP02

You now have a cluster that unseals itself, which means you have moved the
question "who can open this" from a group of key holders to a single service
account on a single other instance. Write down, in one sentence, what happens to
your estate if that instance is lost entirely. CAP05 will ask you to act on the
answer.
