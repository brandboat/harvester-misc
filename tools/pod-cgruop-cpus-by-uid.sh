cat > pod-cgroup-cpus-by-uid.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

uid="${1:?pod UID required}"
uid_us="${uid//-/_}"

pod_cg="$(find /sys/fs/cgroup/kubepods.slice -path "*pod${uid_us}.slice" -type d 2>/dev/null | head -1 || true)"

if [ -z "$pod_cg" ]; then
  echo "pod UID: $uid"
  echo "No pod cgroup found under /sys/fs/cgroup/kubepods.slice"
  exit 1
fi

echo "pod UID: $uid"
echo "pod cgroup: $pod_cg"
echo "pod cpuset.cpus=$(cat "$pod_cg/cpuset.cpus" 2>/dev/null || true)"
echo "pod cpuset.cpus.effective=$(cat "$pod_cg/cpuset.cpus.effective" 2>/dev/null || true)"
echo

find "$pod_cg" -path '*/cgroup.procs' -print | sort | while read -r f; do
  echo "## $f"

  while read -r pid; do
    [ -n "$pid" ] || continue
    [ -d "/proc/$pid" ] || continue

    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    allowed="$(awk '/Cpus_allowed_list/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)"
    affinity="$(taskset -pc "$pid" 2>/dev/null | sed 's/^.*: //' || true)"
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"

    echo
    echo "pid=$pid comm=$comm allowed=$allowed affinity=$affinity"
    echo "cmd=$cmd"
    ps -L -p "$pid" -o pid,tid,psr,stat,pcpu,comm:24,args --no-headers
  done < "$f"

  echo
done
EOF

chmod +x pod-cgroup-cpus-by-uid.sh
