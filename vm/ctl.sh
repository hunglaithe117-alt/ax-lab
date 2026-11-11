#!/usr/bin/env bash
# ctl.sh - control the ax-lab VM from the host.
#
# The lab used to run directly on this machine, which meant one real side effect:
# Substrate's install raises fs.inotify.max_user_instances, and that limit is
# HOST-GLOBAL and not namespaced per container, so the lab changed a kernel
# setting on the host. Everything else was already contained by containers.
#
# Running the lab inside a VM fixes that properly rather than papering over it:
# the VM has its own kernel, so the limit it raises is the VM's. While the VM is
# stopped, nothing of the lab is running at all.
#
#   ./vm/ctl.sh start      start the VM (state from the last session is kept)
#   ./vm/ctl.sh stop       stop the VM - nothing of the lab left running
#   ./vm/ctl.sh status     is it up, and what is inside it
#   ./vm/ctl.sh shell      a shell inside the VM
#   ./vm/ctl.sh verify     run all three lab gates inside the VM
#   ./vm/ctl.sh bootstrap  first-time / repair: build everything from nothing
#   ./vm/ctl.sh reset      rebuild the cluster inside the VM (after a messy stop)
#   ./vm/ctl.sh hostcheck  confirm the host was never modified
#   ./vm/ctl.sh destroy    delete the VM and its disk (irreversible)
set -o errexit -o nounset -o pipefail

VM_NAME="${AXLAB_VM_NAME:-axlab}"
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOUNT_PATH="$LAB_DIR"

# The lab was originally developed with these values; the VM is given the same so
# the environment it runs in matches the one the lessons were verified in.
VM_CPUS=8
VM_MEM=10G
VM_DISK=40G

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

have_multipass() { command -v multipass >/dev/null 2>&1 || die "multipass is not installed"; }

vm_exists() { multipass info "$VM_NAME" >/dev/null 2>&1; }
# Parse `multipass info`, not `multipass list`: the table wraps rows whose IPv4 is
# long (it adds a second line), so column positions are unreliable, and the CSV
# form quotes its fields. `info` is a flat Name:/State: list. The state is
# capitalised there ("Running") and lowercase in `list` output, so normalise
# rather than matching one spelling - getting this wrong makes `status` report
# "(stopped)" for a VM that is plainly running.
vm_running() {
  [ "$(multipass info "$VM_NAME" 2>/dev/null | awk -F': *' '$1=="State"{print tolower($2)}')" = "running" ]
}

# multipass exec does not inherit a login shell, so the PATH the cloud-init
# installed Go into has to be re-established on every exec. Getting this wrong is
# how you get a confusing "go: command not found" halfway through a bootstrap.
vm_exec() { multipass exec "$VM_NAME" -- bash -lc "export PATH=/usr/local/go/bin:\$HOME/go/bin:\$PATH; $*"; }

ensure_mount() {
  # The lab directory is mounted in so there is exactly one copy of the source:
  # you edit on the host, the lab runs in the VM, and they cannot drift apart.
  vm_running || return 0
  vm_lab_path >/dev/null 2>&1 && return 0
  say "mounting $MOUNT_PATH into $VM_NAME"
  if ! multipass mount "$MOUNT_PATH" "$VM_NAME" >/dev/null 2>&1; then
    # Already mounted is success, not failure - `multipass mount` errors when the
    # same path is mounted twice, which is exactly the case we are in after a
    # restart, and the lab is in fact visible.
    vm_lab_path >/dev/null 2>&1 && return 0
    printf 'warning: could not mount %s; the VM has no copy of the lab\n' "$MOUNT_PATH" >&2
    return 1
  fi
  vm_lab_path >/dev/null 2>&1
}

# Where the lab is actually visible INSIDE the VM. Multipass does not necessarily
# reuse the host's absolute path: mounting /home/hung1/personal/ax-lab shows up as
# ~/ax-lab in the guest. Assuming the host path is a bug - `test -d` fails, the
# mount is retried forever, and every `cd` into the lab goes to a missing directory.
vm_lab_path() {
  local base guest_home p
  base="$(basename "$MOUNT_PATH")"
  # Ask the guest for its HOME. Expanding $HOME here would use the *host's* home,
  # and the guest's is a different user, so the candidate would never exist.
  guest_home="$(vm_exec 'printf %s "$HOME"' 2>/dev/null | tr -d '\r\n')"
  for p in "$MOUNT_PATH" "$guest_home/$base" "/mnt/$base" "/media/$base" "/root/$base"; do
    [ -n "$p" ] || continue
    if vm_exec "test -f '$p/scripts/verify-all.sh'" >/dev/null 2>&1; then
      printf '%s' "$p"; return 0
    fi
  done
  return 1
}

cmd_start() {
  have_multipass
  vm_exists || die "no VM named '$VM_NAME'. Create it with: $0 create   (or: ./vm/bootstrap-vm.sh runs after create)"
  vm_running && { say "already running"; ensure_mount; return 0; }
  say "starting $VM_NAME ..."
  multipass start "$VM_NAME" >/dev/null
  say "started. mounting the lab ..."
  ensure_mount
  say "shell in with: $0 shell"
}

cmd_stop() {
  have_multipass
  vm_exists || { say "no VM named '$VM_NAME'"; return 0; }
  vm_running || { say "already stopped"; return 0; }
  say "stopping $VM_NAME (the kind cluster and ax control plane inside it are kept on disk) ..."
  # A plain shutdown, not a delete: the lab's cluster state survives, so the next
  # start is quick. The host is left with no lab processes and no changed sysctls.
  multipass stop "$VM_NAME" >/dev/null
  say "stopped. Nothing of the lab is running now."
}

cmd_status() {
  have_multipass
  vm_exists || { say "no VM named '$VM_NAME'"; return 1; }
  multipass list
  vm_running || { say "(stopped)"; return 0; }
  ensure_mount
  say ""
  vm_exec '
    printf "  kernel            %s\n" "$(uname -r)"
    printf "  cpu / mem         %s / %dG\n" "$(nproc)" "$(awk "/MemTotal/{printf \$2/1048576}" /proc/meminfo)"
    printf "  docker            %s\n" "$(docker --version 2>/dev/null | cut -d, -f1)"
    printf "  go                %s\n" "$(go version 2>/dev/null | cut -d" " -f3)"
    printf "  VM inotify limit  %s   (the VM'"'"'s own; the host has its own)\n" "$(cat /proc/sys/fs/inotify/max_user_instances)"
    printf "  lab mounted at    %s\n" "'"$MOUNT_PATH"'"
    if command -v kind >/dev/null 2>&1; then
      printf "  kind clusters     %s\n" "$(kind get clusters 2>/dev/null | tr "\n" " " || true)"
    fi
    if [ -x "'"$MOUNT_PATH"'/bin/ax" ]; then
      printf "  ax tasks          %s\n" \
        "$(./bin/ax --context kind-ax-lab get tasks 2>/dev/null | tail -n +2 | tr -s " " | tr "\n" ";" || true)"
    fi
  ' 2>/dev/null || true
}

cmd_shell() { have_multipass; vm_exists || die "no VM named '$VM_NAME'"; vm_running || die "VM is stopped - run: $0 start"; ensure_mount; exec multipass shell "$VM_NAME" -- bash -lc 'export PATH=/usr/local/go/bin:$HOME/go/bin:$PATH; exec bash' ; }

cmd_verify() {
  have_multipass; vm_running || die "VM is stopped - run: $0 start"
  ensure_mount
  say "running all three gates inside the VM ..."
  local lab; lab="$(vm_lab_path)" || die "the lab is not mounted in $VM_NAME - try: $0 stop && $0 start"
  vm_exec "cd '$lab' && ./scripts/verify-all.sh && ./scripts/substrate-verify.sh && ./scripts/ax-verify.sh"
}

cmd_bootstrap() {
  have_multipass; vm_running || die "VM is stopped - run: $0 start"
  ensure_mount
  local lab; lab="$(vm_lab_path)" || die "the lab is not mounted in $VM_NAME - try: $0 stop && $0 start"
  vm_exec "bash '$lab/vm/bootstrap-vm.sh'"
}

cmd_hostcheck() {
  # The lab used to raise a host-global kernel limit. Confirm it is not raised.
  local inst watches
  inst="$(cat /proc/sys/fs/inotify/max_user_instances)"
  watches="$(cat /proc/sys/fs/inotify/max_user_watches)"
  say "host fs.inotify limits"
  printf '  max_user_instances = %s   (the stock in-kernel default is 128)\n' "$inst"
  printf '  max_user_watches   = %s   (Ubuntu'"'"'s 30-localsearch.conf sets 65536)\n' "$watches"
  if [ "$inst" = "8192" ]; then
    say "WARNING: max_user_instances is 8192 - that is the value the lab used to set on the HOST."
    say "         Nothing running inside the VM can do that any more. If a previous run left it"
    say "         raised, restore it:  AXLAB_RESTORE_INOTIFY=1 ./scripts/substrate-down.sh"
  elif [ "$inst" = "128" ]; then
    say "OK: the host limit is the stock default. The lab is isolated in the VM."
  else
    say "Note: max_user_instances is $inst, not the stock 128. That is a deliberate local"
    say "      choice rather than something the lab did - the lab's value is 8192. Only a"
    say "      kernel sysctl can set it, and nothing in the VM can reach the host's."
  fi
  say ""
  say "your own containers"
  docker ps --format '  {{.Names}}\t{{.Status}}' 2>/dev/null | head -10 || true
  say ""
  say "your own minikube"
  kubectl --context minikube get ns --no-headers 2>/dev/null | awk '{printf "  %s (%s)\n", $1, $2}' || printf '  (not running)\n'
}

cmd_create() {
  have_multipass
  vm_exists && die "VM '$VM_NAME' already exists"
  say "creating $VM_NAME: ${VM_CPUS} cpu / ${VM_MEM} / ${VM_DISK} on Ubuntu 24.04"
  say "cloud-init installs docker + go 1.27.1 unattended"
  multipass launch --name "$VM_NAME" --cpus "$VM_CPUS" --memory "$VM_MEM" --disk "$VM_DISK" \
    --cloud-init "$LAB_DIR/vm/cloud-init.yaml" 24.04
  ensure_mount
  say "created. Now run: $0 bootstrap"
}

cmd_destroy() {
  have_multipass
  vm_exists || { say "no VM named '$VM_NAME'"; return 0; }
  printf 'This deletes the VM and its %s disk, including the kind cluster and ax inside it.\n' "$VM_DISK"
  printf 'The lab source in %s is NOT touched.\n' "$MOUNT_PATH"
  read -r -p 'Type "destroy" to confirm: ' a
  [ "$a" = "destroy" ] || die "aborted"
  multipass delete "$VM_NAME"
  say "deleted."
}

cmd_reset() {
  have_multipass; vm_running || die "VM is stopped - run: $0 start"
  ensure_mount
  local lab; lab="$(vm_lab_path)" || die "the lab is not mounted in $VM_NAME - try: $0 stop && $0 start"
  say "resetting the lab inside $VM_NAME (rebuilds the kind cluster, ~25 min)"
  say "use this after stopping the VM while actors were running: a gVisor"
  say "checkpoint can never complete once its VM is gone, so those actors are"
  say "stranded and keep holding their workers until the pool is rebuilt."
  vm_exec "cd '$lab' && ./scripts/ax-down.sh; AXLAB_RESTORE_INOTIFY=1 ./scripts/substrate-down.sh; bash ./vm/bootstrap-vm.sh"
}

case "${1:-status}" in
  start|up)      cmd_start ;;
  stop|down)     cmd_stop ;;
  restart)       cmd_stop; cmd_start ;;
  status)        cmd_status ;;
  shell)         cmd_shell ;;
  verify)        cmd_verify ;;
  bootstrap)     cmd_bootstrap ;;
  reset)         cmd_reset ;;
  hostcheck)     cmd_hostcheck ;;
  create)        cmd_create ;;
  destroy)       cmd_destroy ;;
  *) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
