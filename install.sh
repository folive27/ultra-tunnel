#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

WORKDIR="/etc/ultra-tunnel"
BACKHAUL_BIN="$WORKDIR/backhaul"
VERSION="2.0.0"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}خطا: لطفا اسکریپت را با sudo یا کاربر root اجرا کنید.${NC}"
   exit 1
fi

show_banner() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${PURPLE}    __  ____  __                 ______                ${NC}"
    echo -e "${PURPLE}   / / / / / / /__________  ____/_  __/               ${NC}"
    echo -e "${PURPLE}  / / / / / / __/ ___/ __ \/ __ \/ /                  ${NC}"
    echo -e "${PURPLE} / /_/ / /_/ /_/ /  / /_/ / /_/ / /                   ${NC}"
    echo -e "${PURPLE} \____/\____/\__/_/   \____/\____/_/ v$VERSION        ${NC}"
    echo -e "${CYAN}        All-in-One Tunnel (Backhaul + ICMP)         ${NC}"
    echo -e "${CYAN}====================================================${NC}"
}

optimize_system() {
    echo -e "${YELLOW}[*] در حال بهینه‌سازی پارامترهای هسته لینوکس...${NC}"
    
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi

    cat <<EOF > /etc/sysctl.d/99-tunnel.conf
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 65536
EOF
    sysctl --system > /dev/null
    echo -e "${GREEN}[+] سیستم با موفقیت بهینه شد.${NC}"
    sleep 2
}

install_backhaul() {
    echo -e "${YELLOW}[*] در حال نصب هسته Backhaul...${NC}"
    mkdir -p $WORKDIR
    arch=$(uname -m)
    case $arch in
        x86_64) url="https://github.com/Musixal/Backhaul/releases/latest/download/backhaul_linux_amd64.tar.gz" ;;
        aarch64) url="https://github.com/Musixal/Backhaul/releases/latest/download/backhaul_linux_arm64.tar.gz" ;;
        *) echo "معماری پردازنده پشتیبانی نمی‌شود."; return ;;
    esac

    wget -qO backhaul.tar.gz "$url"
    tar -xvf backhaul.tar.gz -C $WORKDIR > /dev/null
    chmod +x $BACKHAUL_BIN
    rm backhaul.tar.gz

    echo -e "${BLUE}1) سرور (خارج - Server)${NC}"
    echo -e "${BLUE}2) کلاینت (ایران - Client)${NC}"
    read -p "نقش سرور را انتخاب کنید: " role

    if [ "$role" == "1" ]; then
        read -p "پورت گوش دادن (مثلا 8080): " port
        read -p "توکن امنیتی (Password): " token
        cat <<EOF > $WORKDIR/config.toml
[server]
bind_addr = "0.0.0.0:$port"
transport = "ws"
token = "$token"
nodisplay = true
mux_version = 2
mux_concurrency = 8
EOF
        create_service "backhaul" "$BACKHAUL_BIN -c $WORKDIR/config.toml"
    else
        read -p "آی‌پی سرور خارج: " remote_ip
        read -p "پورت سرور خارج: " remote_port
        read -p "توکن امنیتی: " token
        read -p "پورت‌های محلی برای تانل (مثلا 443,2053,2083): " ports
        
        cat <<EOF > $WORKDIR/config.toml
[client]
remote_addr = "$remote_ip:$remote_port"
transport = "ws"
token = "$token"
connection_pool = 8
mux_version = 2
EOF
        # افزودن پورت‌ها به کانفیگ کلاینت
        IFS=',' read -ra ADDR <<< "$ports"
        for i in "${ADDR[@]}"; do
            echo -e "[[client.ports]]\nlocal_port = $i\nremote_port = $i" >> $WORKDIR/config.toml
        done
        create_service "backhaul" "$BACKHAUL_BIN -c $WORKDIR/config.toml"
    fi
}

# (Azumi Edition) ---
install_icmp() {
    echo -e "${YELLOW}[*] فراخوانی اسکریپت ICMP آزومی...${NC}"
    bash <(curl -Ls https://raw.githubusercontent.com/Azumi67/icmp_tun/main/icmp.sh)
}

create_service() {
    local name=$1
    local command=$2
    cat <<EOF > /etc/systemd/system/$name.service
[Unit]
Description=$name Tunneling Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$command
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable $name --now
    echo -e "${GREEN}[+] سرویس $name با موفقیت نصب و فعال شد.${NC}"
    sleep 2
}

while true; do
    show_banner
    echo -e "${BLUE}1)${NC} ${WHITE}نصب/آپدیت ${CYAN}Backhaul (Zenith Mod)${NC}"
    echo -e "${BLUE}2)${NC} ${WHITE}نصب/مدیریت ${CYAN}ICMP Tunnel (Azumi)${NC}"
    echo -e "${BLUE}3)${NC} ${WHITE}بهینه‌سازی کامل شبکه ${YELLOW}(BBR & Kernel)${NC}"
    echo -e "${BLUE}4)${NC} ${WHITE}مشاهده وضعیت سرویس‌ها${NC}"
    echo -e "${BLUE}5)${NC} ${RED}حذف کامل و پاکسازی${NC}"
    echo -e "${BLUE}0)${NC} ${WHITE}خروج${NC}"
    echo -e "${CYAN}----------------------------------------------------${NC}"
    read -p "انتخاب شما: " choice

    case $choice in
        1) install_backhaul ;;
        2) install_icmp ;;
        3) optimize_system ;;
        4) systemctl status backhaul --no-pager ;;
        5) 
           systemctl stop backhaul icmp 2>/dev/null
           rm -rf $WORKDIR /etc/systemd/system/backhaul.service
           echo -e "${RED}تمام تنظیمات پاک شد.${NC}"; sleep 2 ;;
        0) exit 0 ;;
        *) echo -e "${RED}گزینه نامعتبر!${NC}"; sleep 1 ;;
    esac
done
