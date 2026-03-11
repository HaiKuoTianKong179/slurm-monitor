# slurm-monitor

一个轻量级 CLI 工具，用于查看 Slurm 集群中剩余的 GPU、CPU 和内存资源。

---

## 使用方法

### 1. 打开 shell 配置文件

```bash
# 使用 nano 编辑 ~/.bashrc 文件（用于添加命令别名）
nano ~/.bashrc
```

### 2. 添加命令别名（在 `~/.bashrc` 文件中）

```bash
# 将 sm 命令绑定到 ~/sm.sh 脚本
alias sm=~/sm.sh
```

### 3. 重新加载配置

```bash
# 重新加载 ~/.bashrc，使刚刚添加的 alias 立即生效
source ~/.bashrc
```

## 运行

```bash
sm
```
