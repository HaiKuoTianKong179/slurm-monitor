#!/usr/bin/env python3
"""sm - 查看集群剩余 GPU / CPU / 内存 与作业队列"""

import json
import re
import subprocess
import time

NODES_CMD = "scontrol show nodes --json"
JOBS_CMD = "scontrol show jobs --json"


def sctl(cmd: str) -> dict:
    """执行 scontrol 命令并解析 JSON"""
    out = subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout
    return json.loads(out)


def short_name(name: str) -> str:
    """去掉 GRES 前缀，'gpu:edition' -> 'edition'"""
    return name.split(":", 1)[-1]


def job_display_id(j: dict) -> str:
    """作业显示 ID：数组任务显示为 '数组ID_任务号'（如 10592_6），普通作业显示 job_id。

    注意：本集群 scontrol --json 的数组信息在顶层 array_job_id/array_task_id 字段，
    不在 array 对象里（array 恒为 {}）。
    """
    ajid = (j.get("array_job_id") or {}).get("number", 0)
    atid = (j.get("array_task_id") or {}).get("number", 0)
    if ajid and atid:
        return f"{ajid}_{atid}"
    return str(j.get("job_id"))


def parse_gres(s: str) -> dict:
    """'gpu:edition:4(S:0-1),...' -> {'gpu:edition': 4, ...}"""
    out = {}
    s = re.sub(r"\([^)]*\)", "", s)  # 去掉 (S:0-1)/(IDX:...) 及其中的逗号
    for item in s.split(","):
        name, _, n = item.rpartition(":")
        if name and n.isdigit():
            out[name] = out.get(name, 0) + int(n)
    return out


def parse_tres(s: str) -> dict:
    """'cpu=2,mem=4G,node=1' -> {'cpu': '2', 'mem': '4G'}"""
    return dict(x.split("=", 1) for x in s.split(",") if "=" in x)


def parse_gpu_req(s: str) -> dict:
    """'gres/gpu:edition:1' -> {'gpu:edition': 1}"""
    out = {}
    name, _, n = s.replace("gres/", "").rpartition(":")
    if n.isdigit() and int(n) > 0:
        out[name] = int(n)
    return out


def fmt_dur(sec: int) -> str:
    """秒 -> 'D-HH:MM:SS'（不足一天则 'HH:MM:SS'）"""
    if sec <= 0:
        return "-"
    d, rem = divmod(int(sec), 86400)
    h, rem = divmod(rem, 3600)
    m, s = divmod(rem, 60)
    return f"{d}-{h:02d}:{m:02d}:{s:02d}" if d else f"{h:02d}:{m:02d}:{s:02d}"


def node_resources(nodes: list) -> dict:
    """汇总所有节点的 GPU / CPU / 内存 资源"""
    gpu_tot, gpu_used = {}, {}
    cpus_tot = cpus_used = mem_tot = mem_used = 0
    for n in nodes:
        for k, v in parse_gres(n.get("gres", "")).items():
            gpu_tot[k] = gpu_tot.get(k, 0) + v
        for k, v in parse_gres(n.get("gres_used", "")).items():
            gpu_used[k] = gpu_used.get(k, 0) + v
        tres = parse_tres(n.get("tres", ""))
        cpus_tot += int(tres.get("cpu", n.get("cpus", 0)))  # 可调度核数（扣系统保留）
        cpus_used += n.get("alloc_cpus", 0)
        mem_tot += n.get("real_memory", 0)
        mem_used += n.get("alloc_memory", 0)
    return {"gpu_tot": gpu_tot, "gpu_used": gpu_used,
            "cpus": (cpus_tot, cpus_used), "mem": (mem_tot, mem_used)}


def job_groups(jobs: list) -> dict:
    """按 GPU 型号分组活跃作业 -> {型号: [(id, 状态, 用户, 名称, 剩余, 数量)]}"""
    groups = {}
    now = int(time.time())
    for j in jobs:
        st = "+".join(j.get("job_state", []))
        if st not in ("RUNNING", "PENDING"):
            continue
        gres = (parse_gres(",".join(j.get("gres_detail") or [])) if st == "RUNNING"
                else parse_gpu_req(j.get("tres_per_node", "")))
        remain = fmt_dur(j.get("end_time", {}).get("number", 0) - now) if st == "RUNNING" else ""
        base = (job_display_id(j), st[0], j.get("user_name") or "",
                j.get("name") or "", remain)
        counts = {("gpu(通配)" if short_name(k) == "gpu" else short_name(k)): v
                  for k, v in gres.items() if v > 0}
        for g, cnt in (counts.items() or [("无 GPU", 0)]):
            groups.setdefault(g, []).append(base + (cnt,))
    return groups


def print_queues(groups: dict) -> None:
    print("作业申请（张数=该型号显卡数, 末列剩余时间）:")
    if not groups:
        print("  (无)")
        return
    for g, infos in groups.items():
        print(f"  [{g}]")
        for jid, st, user, name, remain, cnt in infos:
            print(f"    {jid:<7} {st}  {user:<12} {name:<16} "
                  f"{('-' if not cnt else cnt):>3}张 {remain:>12}")


def print_resources(res: dict) -> None:
    gpu_tot, gpu_used = res["gpu_tot"], res["gpu_used"]
    cpus_tot, cpus_used = res["cpus"]
    mem_tot, mem_used = res["mem"]
    total_free = sum(gpu_tot.values()) - sum(gpu_used.values())
    print(f"剩余 GPU（{total_free} 块）:")
    width = max(len(short_name(k)) for k in gpu_tot)
    for k in gpu_tot:
        tot, used = gpu_tot[k], gpu_used.get(k, 0)
        print(f"  {short_name(k):<{width}}  {tot - used:>2}/{tot}")
    print(f"CPU 剩余: {cpus_tot - cpus_used}/{cpus_tot} 核")
    print(f"内存剩余: {(mem_tot - mem_used) / 1024:.1f}/{mem_tot / 1024:.1f} GB")


def main() -> None:
    nodes = sctl(NODES_CMD)["nodes"]
    jobs = sctl(JOBS_CMD)["jobs"]
    print_queues(job_groups(jobs))
    print_resources(node_resources(nodes))


if __name__ == "__main__":
    main()
