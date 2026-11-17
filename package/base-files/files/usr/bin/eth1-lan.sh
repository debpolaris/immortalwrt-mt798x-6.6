#!/bin/sh
# eth1-lan.sh — 물리 WAN 포트(eth1) 를 LAN 브리지(br-lan) 에 편입한다.
#
# 결과:
#   eth0 = LAN (변경 없음)
#   eth1 = LAN            → 두 포트 모두 LAN
#   network.wan / network.wan6 는 eth1 바인딩을 잃은 채 삭제되고,
#   firewall WAN zone 에서 'wan' 'wan6' 항목도 제거된다.
#
# 인터넷 경로는 5G 모뎀(network.USB -> wwan0_1, defaultroute 1, metric 11) 이므로
# WAN 인터페이스가 사라져도 인터넷은 유지된다.
#
# 되돌리기: /usr/bin/eth1-wan.sh
#
# 주의:
#   * 이 스크립트는 bridge 를 재생성하므로 LAN 링크가 수 초 끊기고 SSH 세션도 끊긴다.
#     그래서 재적용은 백그라운드로 돌리고, 결과 검증에 실패하면 자동 롤백한다.
#   * 재부팅은 하지 않는다.

CFG_NET=/etc/config/network
CFG_FW=/etc/config/firewall
STATUS=/root/.eth1-change-status
LOG=/root/.eth1-change.log
STAMP="$(date +%Y%m%d-%H%M%S)"
BAK_NET="/root/network.bak-lan-${STAMP}"
BAK_FW="/root/firewall.bak-lan-${STAMP}"

[ -f "$CFG_NET" ] || { echo "no $CFG_NET"; exit 1; }

cp "$CFG_NET" "$BAK_NET"
[ -f "$CFG_FW" ] && cp "$CFG_FW" "$BAK_FW"

# 브리지 device 를 이름으로 찾는다 (인덱스 @device[0] 고정 금지).
BRDEV="$(uci show network | grep -E "^network\.[^.]+\.name='br-lan'" | head -1 | cut -d. -f2)"
[ -n "$BRDEV" ] || { echo "br-lan device not found"; exit 1; }

# WAN zone 을 이름으로 찾는다.
WANZONE="$(uci show firewall | grep -E "^firewall\.[^.]+\.name='wan'" | head -1 | cut -d. -f2)"

# ---- eth1 을 LAN 브리지에 편입, WAN 인터페이스에서 분리 ----
uci -q del_list "network.${BRDEV}.ports=eth1"
uci add_list "network.${BRDEV}.ports=eth1"
uci -q delete network.wan
uci -q delete network.wan6
if [ -n "$WANZONE" ]; then
	uci -q del_list "firewall.${WANZONE}.network=wan"
	uci -q del_list "firewall.${WANZONE}.network=wan6"
fi
uci commit network
[ -n "$WANZONE" ] && uci commit firewall

# ---- 백그라운드에서 bridge 재생성 + 검증 + 자동 롤백 ----
rm -f "$STATUS"
setsid sh -c "
	{
		echo '=== eth1-lan.sh $(date -Iseconds 2>/dev/null || date) ==='
		sleep 5
		service network reload
		sleep 20
		if ip link show master br-lan 2>/dev/null | grep -q 'eth1'; then
			echo 'OK: eth1 이 br-lan 에 편입됨' > '$STATUS'
			echo 'OK' >> '$LOG'
		else
			echo 'FAIL: eth1 이 br-lan 에 없음 -> 백업으로 롤백' > '$STATUS'
			cp '$BAK_NET' '$CFG_NET'
			[ -f '$BAK_FW' ] && cp '$BAK_FW' '$CFG_FW'
			service network reload
			echo 'ROLLED_BACK' >> '$STATUS'
			echo 'ROLLED_BACK' >> '$LOG'
		fi
	} >> '$LOG' 2>&1
" >/dev/null 2>&1 &

echo "eth1 -> LAN 적용 예약 완료."
echo "  backup : $BAK_NET"
echo "  15초 후 네트워크가 재구성되며 SSH 가 끊깁니다."
echo "  상태 확인 : cat $STATUS"
echo "  되돌리기: /usr/bin/eth1-wan.sh"
