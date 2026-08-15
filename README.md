# Alpine Optimize

面向 **Alpine Linux**（OpenRC / apk / musl）的聚合工具：官方 BBR 与系统优化、Realm 端口转发、Dante SOCKS5、精简 sing-box。

---

## 远程一键

Alpine 通常直接以 root 登录，一般没有 sudo：

```bash
apk add --no-cache curl bash
curl -fsSL https://raw.githubusercontent.com/yayitinyu/alpine-optimize/main/alpine.sh | bash
```

wget：

```bash
apk add --no-cache wget bash
wget -qO- https://raw.githubusercontent.com/yayitinyu/alpine-optimize/main/alpine.sh | bash
```

带参数时用 `bash -s --`：

```bash
# 一键系统优化（默认 1000Mbps / 亚太）
curl -fsSL https://raw.githubusercontent.com/yayitinyu/alpine-optimize/main/alpine.sh \
  | bash -s -- --all -y

# 指定带宽与跨洋缓冲
curl -fsSL https://raw.githubusercontent.com/yayitinyu/alpine-optimize/main/alpine.sh \
  | bash -s -- --all -y --bandwidth 500 --region overseas

# Realm 转发
curl -fsSL https://raw.githubusercontent.com/yayitinyu/alpine-optimize/main/alpine.sh \
  | bash -s -- realm install --listen 23456 --remote 1.1.1.1:443 --protocol both

# SOCKS5
curl -fsSL https://raw.githubusercontent.com/yayitinyu/alpine-optimize/main/alpine.sh \
  | bash -s -- socks install --port 35678

# 精简 sing-box
curl -fsSL https://raw.githubusercontent.com/yayitinyu/alpine-optimize/main/alpine.sh \
  | bash -s -- sing-box install

# 远程卸载 SOCKS5
curl -fsSL https://raw.githubusercontent.com/yayitinyu/alpine-optimize/main/alpine.sh \
  | bash -s -- socks uninstall --yes
```

交互菜单会从 `/dev/tty` 读键盘。`curl | bash` 打开菜单后应能直接选数字；若仍异常，用已经落下的本地副本：

首次远程执行会把仓库落到 `/opt/alpine-optimize`，之后可直接：

```bash
bash /opt/alpine-optimize/alpine.sh
bash /opt/alpine-optimize/alpine.sh self-update
```

---

## 功能

| 菜单 | 作用 |
| --- | --- |
| 0 | 一键系统优化（不含 SSH 改密） |
| 1 | 系统优化分项：BBR、limits、SWAP、磁盘、工具、清理、引导、时间、熵源 |
| 2 | Realm 端口转发（OpenRC，官方 musl 包） |
| 3 | Dante SOCKS5 |
| 4 | 精简 sing-box：VLESS Reality / Hysteria2 / TUIC v5 / SS2022 |
| 5 | SSH 密钥（可选关密码，默认否） |
| 6 | 查看优化与服务状态 |
| 7 | 卸载优化配置 |

一键优化包含：community 源、GNU 工具、BBR+网络、资源限制、SWAP、noatime、运维工具、每日清理、chrony、haveged。

sing-box 不提供 20 节点、WARP、ACME。Alpine 小鸡内存有限，四条常用入站更合适。

---

## 本地命令

已克隆或已落到 `/opt/alpine-optimize` 时：

```bash
bash alpine.sh --all -y
bash alpine.sh optimize --bbr --bandwidth 1000 --region asia -y
bash alpine.sh realm install --listen 23456 --remote 1.1.1.1:443
bash alpine.sh socks install --port 35678 --host nat.example.com
bash alpine.sh sing-box install --host nat.example.com
bash alpine.sh status
bash alpine.sh self-update
bash alpine.sh uninstall
```

```bash
bash alpine.sh optimize --help
bash alpine.sh realm --help
bash alpine.sh socks --help
bash alpine.sh sing-box --help
```

---

## 文件位置

| 路径 | 用途 |
| --- | --- |
| `/opt/alpine-optimize/` | 远程一键落下的脚本树 |
| `/etc/sysctl.d/99-alpine-optimize.conf` | BBR / TCP / VM sysctl |
| `/etc/security/limits.d/99-alpine-optimize.conf` | nofile / nproc |
| `/etc/rc.conf` 中的 managed block | OpenRC `rc_ulimit` |
| `/etc/local.d/alpine-optimize-boot.start` | 开机恢复 fq / initcwnd |
| `/etc/periodic/daily/alpine-optimize-clean` | 每日清理 |
| `/etc/realm/` | Realm 规则与配置 |
| `/etc/init.d/realm` | Realm OpenRC |
| `/etc/socks5-node/` | SOCKS5 状态 |
| `/opt/alpine-sing-box/` | 精简 sing-box 配置与链接 |
| `/etc/init.d/alpine-sing-box` | sing-box OpenRC |

配置用 drop-in，不整文件覆盖 `/etc/sysctl.conf`。卸载优化配置时**不会**删除 `/swapfile`，也不会回滚 fstab 的 `noatime`。

---

## 注意

- 需要 **root**。面向 Alpine / OpenRC，不要用在 Debian / Ubuntu / RHEL。
- BBR 依赖内核提供 `tcp_bbr`。云主机优先 `linux-virt`；看不到 bbr 时先换内核再 reboot。
- LXC / OpenVZ / 多数容器里，内核参数由宿主机控制，脚本会跳过 SWAP、网卡和模块加载。
- 脚本**不会**擅自启用原本关闭的防火墙，也改不了云安全组。
- SOCKS5 用户名密码不加密传输；sing-box 的 HY2/TUIC 使用自签证书。

本地静态检查：

```bash
bash -n alpine.sh lib/common.sh modules/*.sh
bash tests/test.sh
```
