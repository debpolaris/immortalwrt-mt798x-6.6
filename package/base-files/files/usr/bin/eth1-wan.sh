#!/bin/sh
# eth1-wan.sh — 물리 포트 eth1 을 WAN 인터페이스로 되돌린다.
#
# 결과:
#   eth0 = LAN (변경 없음)
#   eth1 = WAN            → network.wan(dhcp) / network.wan6(dhcpv6)
#   firewall WAN zone 에 'wan' 'wan6' 항목이 복구된다.
#
# eth1-lan.sh 로 바꿨다가 되돌릴 때 쓴다.
# 인터넷은 5G 모뎀(network.USB) 경유이므로 이 설정은 상관없이 인터넷이 유지된다.
#
# 주의:
#   * bridge 가 재생성되므로 LAN 링크가 수 초 끊기고 SSH 세션도 끊긴다.
#   * 재부팅은 하지 않는다.

CFG_NET=/etc/config/network
CFG_FW=/etc/config/firewall
STATUS=/root/.eth1-change-status
LOG=/root/.eth1-change.log
STAMP="$(date +%Y%m%d-%H%M%S)"
BAK_NET="/root/network.bak-wan-${STAMP}"
BAK_FW="/root/firewall.bak-wan-${STAMP}"

[ -f "$CFG_NET" ] || { echo "no $CFG_NET"; exit 1; }

cp "$CFG_NET" "$BAK_NET"
[ -f "$CFG_FW" ] && cp "$CFG_FW" "$BAK_FW"

BRDEV="$(uci show network | grep -E "^network\.[^.]+\.name='br-lan'" | head -1 | cut -d. -f2)"
[ -n "$BRDEV" ] || { echo "br-lan device not found"; exit 1; }

WANZONE="$(uci show firewall | grep -E "^firewall\.[^.]+\.name='wan'" | head -1 | cut -d. -f2)"

# ---- eth1 을 브리지에서 빼고 WAN 인터페이스로 되돌린다 ----
uci -q del_list "network.${BRDEV}.ports=eth1"

if uci -q get network.wan.device >/dev/null 2>&1; then
	uci set network.wan.device='eth1'
else
	uci set network.wan=interface
	uci set network.wan.device='eth1'
	uci set network.wan.proto='dhcp'
fi
if uci -q get network.wan6.device >/dev/null 2>&1; then
	uci set network.wan6.device='eth1'
else
	uci set network.wan6=interface
	uci set network.wan6.device='eth1'
	uci set network.wan6.proto='dhcpv6'
fi

if [ -n "$WANZONE" ]; then
	uci -q del_list "firewall.${WANZONE}.network=wan"
	uci add_list "firewall.${WANZONE}.network=wan"
	uci -q del_list "firewall.${WANZONE}.network=wan6"
	uci add_list "firewall.${WANZONE}.network=wan6"
fi

uci commit network
[ -n "$WANZONE" ] && uci commit firewall

# ---- 백그라운드에서 bridge 재생성 + 검증 + 자동 롤백 ----
rm -f "$STATUS"
setsid sh -c "
	{
		echo '=== eth1-wan.sh $(date -Iseconds 2>/dev/null || date) ==='
		sleep 5
		service network reload
		sleep 20
		if uci -q get network.wan.device 2>/dev/null | grep -q eth1 &&
		   ! ip link show master br-lan 2>/dev/null | grep -q 'eth1'; then
			echo 'OK: eth1 이 WAN 으로 복원됨' > '$STATUS'
			echo 'OK' >> '$LOG'
		else
			echo 'FAIL: eth1 WAN 복원 실패 -> 백업으로 롤백' > '$STATUS'
			cp '$BAK_NET' '$CFG_NET'
			[ -f '$BAK_FW' ] && cp '$BAK_FW' '$CFG_FW'
			service network reload
			echo 'ROLLED_BACK' >> '$STATUS'
			echo 'ROLLED_BACK' >> '$LOG'
		fi
	} >> '$LOG' 2>&1
" >/dev/null 2>&1 &

echo "eth1 -> WAN 적용 예약 완료."
echo "  backup : $BAK_NET"
echo "  15초 후 네트워크가 재구성되며 SSH 가 끊깁니다."
echo "  상태 확인 : cat $STATUS"
echo "  LAN 으로: /usr/bin/eth1-lan.sh"
