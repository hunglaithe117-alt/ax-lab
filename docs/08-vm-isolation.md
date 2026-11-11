# Running the lab in a VM

The lab originally ran directly on this machine. That worked, with one real
consequence: **Substrate's install raises `fs.inotify.max_user_instances`, and that
limit is host-global and not namespaced per container**, so installing the lab changed a
kernel setting on the host and left it raised. Everything else was already contained by
Docker.

This page is about the fix: an `axlab` virtual machine that owns the whole lab, so the
host is never modified and the lab is genuinely easy to switch on and off.

Start here:

```bash
./vm/ctl.sh start      # bring it up
./vm/ctl.sh status     # what is running inside
./vm/ctl.sh verify     # all three lab gates
./vm/ctl.sh stop       # nothing of the lab is left running
./vm/ctl.sh hostcheck  # prove the host was not modified
```

## What the VM is

| | |
|---|---|
| Tool | `multipass` (the `lxd` group is already required; no root, no sudo) |
| Driver | `qemu` with KVM — `/dev/kvm` is group/world accessible and `KVM_CREATE_VM` succeeds here |
| Base | Ubuntu 24.04 LTS, provisioned unattended by `vm/cloud-init.yaml` |
| Size | 8 vCPU / 10G RAM / 40G disk |
| Kernel | the VM's own (`6.8.0-142-generic` at time of writing) — the host is on a different one |

Cloud-init installs Docker, Go 1.27.1 (ax's `go.mod` requires it; Ubuntu ships 1.22),
`kubectl`, `kind` v0.33.0 and `ko` v0.19.1, so a fresh VM needs no manual steps.

`fs.inotify.max_user_instances` is what the lab raises. Inside the VM that is the **VM's**
limit. The host's value is a completely separate number in a different kernel.

## Where the files live

`vm/ctl.sh` mounts this directory into the VM, so there is **one** copy of the source:
you edit on the host, the lab runs in the VM, and they cannot drift. Multipass uses 9p
for this, which needs no root and survives stop/start.

The 2GB Substrate checkout is the exception — building from a 9p mount is miserable — so
it lives on the VM's own disk (`~/axlab-cache/substrate`) and the lab is pointed at it
through `AXLAB_SUBSTRATE_DIR`, an override the scripts already supported.

`upstream/google-ax` (~30MB) stays on the mount; it is small and `setup.sh` manages it.

## Sizing: what actually consumes memory

Measured inside the VM, from the kind node's own accounting:

| Consumer | Requests |
|---|---|
| Substrate control plane (ateapi, atelet, atenet, postgres, rustfs, envoy, prometheus, otel, jaeger, podcertcontroller) + ax (redis, ax-server, ax-controller) | ~1.6G |
| Counter demo pool (Substrate's own, 3 × 1Gi) | 3G |
| ax worker pool | 2 × 2G = 4G |
| **Total** | **~8.6G of the node's 9.7G allocatable** |

Two sizing mistakes, both recorded in `vm/bootstrap-vm.sh`:

1. **The ax worker pool needs 2 replicas, not 1.** A suspend/resume needs somewhere to
   land: the suspended actor still holds its worker until the checkpoint finishes, so
   resuming onto a 1-replica pool fails with `no free workers available` and the task goes
   to phase `Failed`. This was found the hard way, by shrinking to 1 "to save RAM" and
   watching resume fail. The host default of 2 is not arbitrary.
2. **`4Gi` in `ax-up.sh`'s default is a limit; the scheduler weighs requests.** At 2Gi
   requests everything fits. At 4Gi requests the total overruns the node and the worker pod
   never schedules (`1 Insufficient memory`) — which is what started this.

The counter demo stays at Substrate's own 3. An earlier version of the bootstrap shrank it
to 1 "to save memory", which was wrong twice over: the memory was never going there, and a
1-worker pool cannot reliably serve a suspend/resume either.

## Stopping the VM: the one real caveat

**Suspend or delete running actors before you stop the VM.** A gVisor checkpoint cannot
complete once the VM hosting the sandbox is gone, so the actor is left stranded in
`ACTOR_STATE_SUSPENDED`-never-reached — specifically `ACTOR_STATE_SUSPENDING` — and
Substrate refuses to delete it, because it only allows deletion of a fully suspended actor.
`vm/bootstrap-vm.sh` handles this by detecting a stranded actor and moving on to a fresh
name (`AXLAB_ACTOR`), which the Phase 2 gate already supports. The stranded actor is inert
but it holds its worker, so repeated stop/starts can exhaust a pool.

The clean habit:

```bash
./vm/ctl.sh shell   # then, inside:  cd ~/ax-lab && ./scripts/ax-down.sh && ./scripts/substrate-down.sh
./vm/ctl.sh stop
```

## Gate findings from running it in the VM

The slower, smaller machine surfaced two defects that the fast host never showed. Both are
fixed; both are the kind of thing a gate exists to catch.

1. **A read-once where the neighbouring read polls.** `ax-verify.sh` polled for the actor
   after `ax apply` but read the Task's `phase` exactly once. On the host that always won
   the race; in the VM it lost, and reported `phase <none>` on a perfectly healthy Task.
   Now polled like its neighbour.
2. **`substrate-down.sh` assumed a `minikube` context exists.** It reads the user's
   minikube namespaces as a safety check before deleting anything, and the script runs
   under `set -o errexit -o pipefail` — so in a VM with no minikube, the failing `kubectl`
   inside that pipeline aborted the teardown *before it deleted anything*. That is why an
   earlier teardown silently did nothing. The check is now guarded on the context existing,
   and degrades to the warning it already had.

### A gate check that cannot recover after a restart

`substrate-verify.sh` asserts no pod has restarted more than twice. Restart counters are
cumulative and never decay, so after **any** VM stop/start a couple of pods
(`postgres-0`, `local-path-provisioner`) carry boot-time counts and that check fails
permanently until those pods are recreated:

```bash
kubectl --context kind-ax-lab delete pod postgres-0 -n ate-system
kubectl --context kind-ax-lab delete pod -n local-path-storage -l app=local-path-provisioner
```

This is a genuine weakness for a lab whose whole point is being stoppable: the check
distinguishes "crash-looping now" from "ever crashed", and only the former is what anyone
cares about. Worth changing to a rate check. It was left as-is rather than edited silently,
because the gate has been through review.

## Verified state

All three gates pass inside the VM:

```
P1 verify-all.sh        exit 0    5 passed
P2 substrate-verify.sh  exit 0   10 passed
P3 ax-verify.sh         exit 0   27 passed
```

including `ax ssh` into a live gVisor sandbox (`Linux 4.19.0-gvisor x86_64`, `uid=0`,
`/workspace` containing the cloned repo), and a suspend/resume whose per-actor snapshot
lands on the corrected bucket.

## Cost and what is left behind

While running, the VM holds 8 vCPU, 10G RAM and up to 40G disk. While **stopped**, nothing
of the lab is running: no process, no container, no cluster.

`./vm/ctl.sh destroy` deletes the VM and its disk. The lab source in this directory is a
host mount and is not touched.
