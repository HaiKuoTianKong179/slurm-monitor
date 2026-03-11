#!/usr/bin/env bash
# Slurm 剩余可申请资源：CPU、内存(GB)、GPU（支持显卡切分）
set -e

# 获取节点资源第一行：%C(CPU状态) %e(空闲内存MB) %G(GRES) %n(节点名)
line=$(sinfo -h -o "%C %e %G %n" | head -1)

idle_cpu=$(echo "$line" | awk '{split($1,a,"/"); print a[2]+0}')
node=$(echo "$line" | awk '{print $4}')
node_info=$(scontrol show node "$node" 2>/dev/null || true)

# 真实可申请内存：RealMemory - AllocMem（MB）
free_mem_mb=$(echo "$node_info" | awk '
{
  for (i=1; i<=NF; i++) {
    if ($i ~ /^RealMemory=/) { split($i,a,"="); real=a[2] }
    if ($i ~ /^AllocMem=/)   { split($i,a,"="); alloc=a[2] }
  }
}
END {
  if (real == "" || alloc == "") print ""
  else print real - alloc
}')

# 逐类型统计可申请 GPU：free = CfgTRES(gres/gpu:<type>) - AllocTRES(gres/gpu:<type>)
free_gpu_by_type=$(echo "$node_info" | awk '
{
  for (i=1; i<=NF; i++) {
    if ($i ~ /^CfgTRES=/)   { sub(/^CfgTRES=/, "", $i); cfg_line=$i }
    if ($i ~ /^AllocTRES=/) { sub(/^AllocTRES=/, "", $i); alloc_line=$i }
  }
}
END {
  n=split(cfg_line, cfg_items, ",")
  for (i=1; i<=n; i++) {
    split(cfg_items[i], kv, "="); key=kv[1]; val=kv[2]+0
    if (key ~ /^gres\/gpu:/) {
      type=key; sub(/^gres\/gpu:/, "", type)
      if (!(type in seen)) { seen[type]=1; order[++k]=type }
      cfg[type]=val
    }
  }

  m=split(alloc_line, alloc_items, ",")
  for (i=1; i<=m; i++) {
    split(alloc_items[i], kv, "="); key=kv[1]; val=kv[2]+0
    if (key ~ /^gres\/gpu:/) {
      type=key; sub(/^gres\/gpu:/, "", type)
      alloc[type]=val
    }
  }

  if (k==0) { printf "-"; exit }
  for (i=1; i<=k; i++) {
    t=order[i]
    v=cfg[t]-alloc[t]
    if (v < 0) v=0
    if (v == int(v)) out=sprintf("%s:%d", t, v)
    else out=sprintf("%s:%.2f", t, v)
    printf "%s%s", out, (i<k ? ", " : "")
  }
}')

if [[ -n "$free_mem_mb" ]]; then
  (( free_mem_mb < 0 )) && free_mem_mb=0
  free_mem_gb=$(awk "BEGIN {printf \"%.2f\", $free_mem_mb/1024}")
else
  # 回退：使用 sinfo %e
  free_mem_gb=$(echo "$line" | awk '{printf("%.2f",$2/1024)}')
fi

pow2_floor() {
  local n="$1"
  local p=1
  while (( p * 2 <= n )); do p=$((p * 2)); done
  echo "$p"
}

cpu_req=1
if (( idle_cpu >= 1 )); then
  cpu_req=$(pow2_floor "$idle_cpu")
fi

mem_req_gb=1
if [[ -n "$free_mem_mb" ]] && (( free_mem_mb >= 1024 )); then
  mem_free_gb_int=$((free_mem_mb / 1024))
  mem_req_gb=$(pow2_floor "$mem_free_gb_int")
fi

gpu_type="a100"
gpu_req=1
if [[ "$free_gpu_by_type" != "-" ]]; then
  IFS=',' read -ra gpu_items <<< "$free_gpu_by_type"
  for item in "${gpu_items[@]}"; do
    item="${item# }"
    t="${item%%:*}"
    v="${item##*:}"
    v_int="${v%%.*}"
    if [[ "$v_int" =~ ^[0-9]+$ ]] && (( v_int >= 1 )); then
      gpu_type="$t"
      gpu_req=$(pow2_floor "$v_int")
      break
    fi
  done
fi
echo "空闲CPU: $idle_cpu  空闲内存: ${free_mem_gb} GB  空闲GPU(分类型): $free_gpu_by_type"
echo "最大可申请资源示例(2的次方, 可复制修改): srun -p gpu_short --gres=gpu:${gpu_type}:${gpu_req} -c ${cpu_req} --mem=${mem_req_gb}G --pty bash"