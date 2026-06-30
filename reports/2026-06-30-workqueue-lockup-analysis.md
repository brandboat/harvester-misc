# LHv2 Workqueue Lockup Analysis

## Environment Setup

Three harvester nodes, all are installed in the bare metal machines:

- `harvester-node-1`
- `hp-114-tink-system`
- `hp-161-tink-system`

All three nodes were running with Longhorn V2 enabled. `harvester-node-1` only has one disk, no extra ssd.

- Kernel: `6.12.0-160000.32-default`
- Harvester: `70017a32` ([v1.9.0-dev-20260621](https://github.com/harvester/harvester/releases/tag/v1.9.0-dev-20260621))
- Kubernetes/RKE2: `v1.35.5+rke2r1`
- Longhorn: `v1.12.0`, all longhorn nodes v2 disk driver are `nvme`.
- The LHv2 CPU Mask is set to `0xC`, which maps to CPUs 2 and 3.

## Symptom

The issue was found in `journalctl`: the kernel repeatedly reported workqueue lockups after LHv2 was enabled and V2 volume activity started.

Example from the support bundle:

```text
BUG: workqueue lockup - pool cpus=2 node=0 flags=0x0 nice=0 stuck for 53s!
```

On `harvester-node-1`, the same lockup continued for a long time, eventually reporting very large stuck durations:

```text
BUG: workqueue lockup - pool cpus=2 node=0 flags=0x0 nice=0 stuck for 10693s!
```

Not only `harvester-node-1`, `hp-161-tink-system`, `hp-114-tink-system` all have same sypmtons.

## Initial Analysis

From the workqueue lockup log:

```text
Jun 29 07:35:26 harvester-node-1 kernel: BUG: workqueue lockup - pool cpus=3 node=0 flags=0x0 nice=0 stuck for 649s!
Jun 29 07:35:26 harvester-node-1 kernel: Showing busy workqueues and worker pools:
Jun 29 07:35:26 harvester-node-1 kernel: workqueue events: flags=0x0
Jun 29 07:35:26 harvester-node-1 kernel:   pwq 2: cpus=0 node=0 flags=0x0 nice=0 active=2 refcnt=3
Jun 29 07:35:26 harvester-node-1 kernel:     in-flight: 3346265:drm_fb_helper_damage_work drm_fb_helper_damage_work
Jun 29 07:35:26 harvester-node-1 kernel:   pwq 14: cpus=3 node=0 flags=0x0 nice=0 active=1 refcnt=2
Jun 29 07:35:26 harvester-node-1 kernel:     in-flight: 2990528:output_poll_execute
Jun 29 07:35:26 harvester-node-1 kernel: workqueue events_power_efficient: flags=0x80
Jun 29 07:35:26 harvester-node-1 kernel:   pwq 14: cpus=3 node=0 flags=0x0 nice=0 active=1 refcnt=2
Jun 29 07:35:26 harvester-node-1 kernel:     pending: gc_worker [nf_conntrack]
Jun 29 07:35:26 harvester-node-1 kernel: workqueue mm_percpu_wq: flags=0x8
Jun 29 07:35:26 harvester-node-1 kernel:   pwq 14: cpus=3 node=0 flags=0x0 nice=0 active=1 refcnt=2
Jun 29 07:35:26 harvester-node-1 kernel:     pending: vmstat_update
Jun 29 07:35:26 harvester-node-1 kernel: pool 2: cpus=0 node=0 flags=0x0 nice=0 hung=0s workers=3 idle: 3425634 3381768
Jun 29 07:35:26 harvester-node-1 kernel: pool 14: cpus=3 node=0 flags=0x0 nice=0 hung=649s workers=2 idle: 2721593
Jun 29 07:35:26 harvester-node-1 kernel: Showing backtraces of running workers in stalled CPU-bound worker pools:
Jun 29 07:35:26 harvester-node-1 kernel: pool 14:
Jun 29 07:35:26 harvester-node-1 kernel: task:kworker/3:1     state:R  running task     stack:0     pid:2990528 tgid:2990528 ppid:2      flags:0x00004000
Jun 29 07:35:26 harvester-node-1 kernel: Workqueue: events output_poll_execute
Jun 29 07:35:26 harvester-node-1 kernel: Call Trace:
Jun 29 07:35:26 harvester-node-1 kernel:  <TASK>
Jun 29 07:35:26 harvester-node-1 kernel:  __schedule+0x401/0x1400
Jun 29 07:35:26 harvester-node-1 kernel:  ? asm_sysvec_reschedule_ipi+0x1a/0x20
Jun 29 07:35:26 harvester-node-1 kernel:  ? update_curr+0x19a/0x220
Jun 29 07:35:26 harvester-node-1 kernel:  schedule+0x27/0xf0
Jun 29 07:35:26 harvester-node-1 kernel:  try_address+0x5a/0x80 [i2c_algo_bit 6be8c54dbbe1387afc24b2f5b3f10a41c743ab05]
Jun 29 07:35:26 harvester-node-1 kernel:  bit_xfer+0x22a/0x5a0 [i2c_algo_bit 6be8c54dbbe1387afc24b2f5b3f10a41c743ab05]
Jun 29 07:35:26 harvester-node-1 kernel:  ? finish_task_switch.isra.0+0x99/0x2d0
Jun 29 07:35:26 harvester-node-1 kernel:  __i2c_transfer+0x1a9/0x550
Jun 29 07:35:26 harvester-node-1 kernel:  i2c_transfer+0x80/0xd0
Jun 29 07:35:26 harvester-node-1 kernel:  drm_do_probe_ddc_edid+0xc7/0x150
Jun 29 07:35:26 harvester-node-1 kernel:  drm_probe_ddc+0x2e/0x60
Jun 29 07:35:26 harvester-node-1 kernel:  drm_connector_helper_detect_from_ddc+0x1a/0x40
Jun 29 07:35:26 harvester-node-1 kernel:  mgag200_vga_bmc_connector_helper_detect_ctx+0x25/0x40 [mgag200 f25b41272eeef7796163a329aa33df250e4fa3aa]
Jun 29 07:35:26 harvester-node-1 kernel:  drm_helper_probe_detect_ctx+0x44/0xf0
```

We know that cpu 3 overlaps with the intended LHv2/SPDK CPU mask:

```text
0xC = CPUs 2 and 3
```

From this script, we can get some information about IRQs and workqueues:
```sh
echo "=== cmdline ==="
cat /proc/cmdline

echo "=== workqueue cpumask ==="
cat /sys/devices/virtual/workqueue/cpumask

echo "=== SPDK/kworker placement ==="
ps -eLo pid,tid,psr,cls,rtprio,pri,ni,stat,pcpu,wchan:30,comm,args | \
  egrep 'spdk|reactor|kworker/2|kworker/3|ksoftirqd/2|ksoftirqd/3'

echo "=== IRQs still on CPU2/3 ==="
for irqdir in /proc/irq/[0-9]*; do
  irq=$(basename "$irqdir")
  eff=$(cat "$irqdir/effective_affinity_list" 2>/dev/null)
  conf=$(cat "$irqdir/smp_affinity_list" 2>/dev/null)
  if echo "$eff" | grep -Eq '(^|,|-)2($|,|-)|(^|,|-)3($|,|-)'; then
    echo "IRQ=$irq configured=$conf effective=$eff"
    grep -w "^ *$irq:" /proc/interrupts 2>/dev/null
  fi
done
```

From the script output, we can see that device IRQs are effectively landing on CPU2/CPU3, for example:
```
IRQ=109 configured=0-5,12-17 effective=2  eno49-TxRx-5
IRQ=110 configured=0-5,12-17 effective=3  eno49-TxRx-6
IRQ=121 configured=0-5,12-17 effective=2  eno49-TxRx-17
IRQ=122 configured=0-5,12-17 effective=3  eno49-TxRx-18
```

These are NIC IRQs. The interrupt counts are huge:
```
eno49-TxRx-5   CPU2 count ≈ 82M
eno49-TxRx-6   CPU3 count ≈ 61M
```

and workqueues are allowed on all CPUs 0-23
```
=== workqueue cpumask ===
ffffff
```

From the kernel log above
```
Jun 29 07:35:26 harvester-node-1 kernel: task:kworker/3:1     state:R  running task     stack:0     pid:2990528 tgid:2990528 ppid:2      flags:0x00004000

```

we can see that process 2990528 hit a soft lockup. This matches what we observed from the workqueue usage:
```
=== SPDK/kworker placement ===
PID     TID     PSR CLS RTPRIO PRI NI STAT %CPU WCHAN                          COMMAND          ARGS
2990528 2990528   3  TS      -  19   0 R     0.0 -                              kworker/3:1+eve [kworker/3:1+events]
```

## Does Lockup Matter?

This matters because CPUs 2 and 3 were intended for LHv2/SPDK. If SPDK is busy-polling on those CPUs and the kernel also queues per-CPU or unbound work there, that kernel work can be delayed long enough to trigger the lockup detector. And even worse, make the whole kernel unstable.

## What We Tried

We've investigate several cpu related kernel settings, and try to do some experiments with combinations.

- [CPU Isolation](https://wiki.linuxfoundation.org/realtime/documentation/howto/tools/cpu-partitioning/isolcpus?s[]=isolcpus)
- [IRQ Affinity](https://wiki.linuxfoundation.org/realtime/documentation/howto/tools/cpu-partitioning/irqaffinity)
- [Kubelet Reserved CPUs](https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/#explicitly-reserved-cpu-list)

### ❌ CPU Isolation

The following kernel parameters were tested:

```text
isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3
```

Result:

In kernel log we found NVMe starts repeating reporting below error messages unstable and kubelet not responding after several minutes:

```text
Jun 25 07:45:13 hp-161-tink-system kernel: nvme nvme0: creating 48 I/O queues.
Jun 25 07:45:14 hp-161-tink-system kernel: nvme nvme0: mapped 48/0/0 default/read/poll queues.
Jun 25 07:45:14 hp-161-tink-system kernel: nvme nvme0: Connect command failed, errno: -18
Jun 25 07:45:14 hp-161-tink-system kernel: nvme nvme0: failed to connect queue: 27 ret=-18
Jun 25 07:45:15 hp-161-tink-system kernel: nvme nvme0: creating 48 I/O queues.
Jun 25 07:45:15 hp-161-tink-system kernel: nvme nvme0: mapped 48/0/0 default/read/poll queues.
Jun 25 07:45:15 hp-161-tink-system kernel: nvme nvme0: Connect command failed, errno: -18
Jun 25 07:45:15 hp-161-tink-system kernel: nvme nvme0: failed to connect queue: 27 ret=-18
...
```

- Workqueue lockups still happened.
- Kubelet became unresponsive after several minutes.
- SSD disappear after several minutes
- The node could transition into an unhealthy state.

```
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
loop0    7:0    0    3G  1 loop /
sda      8:0    0  1.6T  0 disk
├─sda1   8:1    0   64M  0 part
├─sda2   8:2    0   50M  0 part /oem
├─sda3   8:3    0    8G  0 part
├─sda4   8:4    0   15G  0 part /run/initramfs/cos-state
├─sda5   8:5    0  150G  0 part /var/lib/kubelet/pods/31724c46-6cb0-48b5-85d7-e653f1d2feb4/volume-subpaths/multus-cfg/kube-rke2-multus/2
│                               /var/lib/longhorn
│                               /var/crash
│                               /var/lib/third-party
│                               /var/lib/cni
│                               /var/lib/NetworkManager
│                               /var/lib/wicked
│                               /var/lib/kubelet
│                               /var/lib/rancher
│                               /var/log
│                               /usr/libexec
│                               /root
│                               /opt
│                               /home
│                               /etc/pki/trust/anchors
│                               /etc/cni
│                               /etc/nvme
│                               /etc/iscsi
│                               /etc/ssh
│                               /etc/rancher
│                               /etc/systemd
│                               /etc/NetworkManager
│                               /usr/local
└─sda6   8:6    0  1.5T  0 part /var/lib/harvester/defaultdisk
```

### ❌ CPU Isolation + Kubelet Reserved CPUs

The test also reserved CPUs 2 and 3 from kubelet scheduling:

set below in `/etc/rancher/rke2/config.yaml/99-z01-harvester-cpu-manager.yaml`

```text
kubelet-arg+:
- "cpu-manager-policy=static"
- "reserved-cpus=2,3"
```

/oem/grubenv
```text
isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3
```

Result:
- Workqueue lockups still happened.
- Kubelet became unresponsive after several minutes.
- The node could transition into an unhealthy state.
- ssd disk disappear

### ❌ CPU Isolation + Kubelet Reserved CPUs + IRQ Affinity

/oem/grubenv
```text
isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3 irqaffinity=0,1,4-23
```
/etc/rancher/rke2/config.yaml/99-z01-harvester-cpu-manager.yaml
```text
kubelet-arg+:
- "cpu-manager-policy=static"
- "reserved-cpus=2,3"
```

Result:
- No new workqueue lockup messages were observed during that test window.
- Kubelet became unresponsive after several minutes.
- The node could transition into an unhealthy state.
- ssd disk disappear

### ✅ IRQ Affinity

```text
irqaffinity=0,1,4-23
```

Results:
- Multiple VMs could be provisioned.
- Kubelet stayed responsive.
- No new workqueue lockup messages were observed during that test window.

## Reproduction

The issue is not consistently reproducible in every environment.

If we install harvester in vm via [ipxe-example](https://github.com/harvester/ipxe-examples/tree/main/vagrant-pxe-harvester), the workqueue lockup doesn't always happen. We've observed during bootstraping harvester, the workqueue lockup message show up once, but then never being raised again.

## Summary

After enabling Longhorn V2, multiple bare-metal nodes showed kernel workqueue lockup messages during or shortly after V2 volume activity. The support bundle and prior live investigation both point to the same pattern: the lockups occur on CPUs assigned to LHv2/SPDK, while the kernel still expects those CPUs to handle normal kernel work.

The current best findings are:

- `isolcpus`, `nohz_full`, and `rcu_nocbs` alone do not eliminate the lockup.
- Kubelet `reserved-cpus` but it does not stop kernel workqueues or IRQ-related work from using those CPUs.
- CPU isolation led to severe rke2 instability, including NVMe access errors, but if we stop lhv2, everyting is fine, kubelet stays healthy.
- A node does not need to host the local LHv2 volume data to hit the issue; if SPDK is enabled on CPUs 2 and 3 and kernel work can still land there, workqueue lockups can still occur.
- Using `irqaffinity` alone looked like the most successful mitigation so far.

The likely root problem is CPU placement contention between SPDK busy-polling and kernel housekeeping work.

## What to do next?

To be honest, this situation is a bit tricky. If a client runs into a similar issue while using lhv2, how should we guide them through it? Should we advise them to manually add irqaffinity in grubenv and reboot, while recommending they avoid modifying cpumask? It seems that whenever cpumask is adjusted, irqaffinity needs to be reconfigured as well.

The scenario becomes even more complex with the new CPU core settings (https://github.com/longhorn/longhorn/issues/13248). If this feature is enabled, CPU allocation changes dynamically, which means users would have to manually adjust settings every time the CPU allocated to the IM changes.

Currently there are 2 ways to deal with this situation:
1. Set IRQ Affinity on the fly
2. Enable LHv2 interrupt mode

### Set IRQ Affinity on the fly

- IRQ Affinity can be set on the fly, we can to set irq affinity in the instance manager pod, irq affinity can be set right before launch spdk process startup. But this needs longhorn team effort.

### Rejected Alternatives

- Enable lhv2 interrupt mode can also mitigate the workqueue lockup issue, but spdk interrupt mode still have several issues and under development, this need further investigation. Besides that, Derek also mentioned interrupt mode still squeeze at least one cpu full resource, enable it doesn't mean every cpu have room for other processes to jump in.

## Need Further Investigation

- The reason why isolcpus make kubelet not responding is unclear.
