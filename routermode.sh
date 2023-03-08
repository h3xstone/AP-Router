#!/bin/bash

# global
LOGFD="routermode.log"
pkgReq=("hostapd" "dnsmasq" "iptables-persistent")
declare -A listfc
listfc[dhcpcd]="/etc/dhcpcd.conf"
listfc[dnsmasq]="/etc/dnsmasq.conf"
listfc[hostapd]="/etc/hostapd/hostapd.conf"

# color output
function perr(){
	tput setaf 1
	echo -n $@
	tput sgr0
}

function psuc(){
	tput setaf 2
	echo -n $@
	tput sgr0
}

function pwarn(){
	tput setaf 3
	echo -n $@
	tput sgr0
}

# func validate ip
function validIp(){
	ip=$1
	if [[ "$ip" =~ ^(([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))\.){3}([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))$ ]]
	then
		return 0
	else
		return 1
	fi
}

# check requirements
function checkRequirements(){
	echo "[*] check required packages"
	err=0
	for p in ${pkgReq[@]}
	do
		echo -e "\n--- check requisite: $p ---\n" >>$LOGFD
		dpkg-query -W -f='${Status}' $p 2>>$LOGFD | grep -iw 'install' &>>$LOGFD
		if [[ $? -eq 0 ]]
		then
			echo "[+] $p $(psuc installed)"
		else
			echo "[-] $p $(perr not installed. Required!)"
			let "err++"
		fi
	done
	
	if [[ $err -ne 0 ]]
	then
		echo ""
		echo $(perr "ERROR: required packages must be installed!")
		echo ""
		exit 0
	fi	
}

# show ap info
function getInfo(){
	if [[ ! $iface_in ]]
	then
		iface_in=$(grep -Po '(?<=interface=)[^ ]*' ${listfc[dnsmasq]})
	fi
	if [[ ! $iface_out ]]
	then
		iface_out=$(iptables -t nat -S | grep -Po '(?<=\-A POSTROUTING \-o ).*(?= \-j MASQUERADE$)')
	fi
	iprouter=$(grep -Po '(?<=listen-address=)[^ ]*' ${listfc[dnsmasq]} | cut -d',' -f3)
	iprl=$(grep -Po '(?<=dhcp-range=)[^ ]*' ${listfc[dnsmasq]} | cut -d',' -f1)
	iprh=$(grep -Po '(?<=dhcp-range=)[^ ]*' ${listfc[dnsmasq]} | cut -d',' -f2)
	
	echo ""
	echo "********************************** SUMMARY **********************************"
	# if iface_in = wifi show Ap info
	if [[ "$(iwconfig $iface_in 2>&1 | awk '{print $2,$3,$4}')" =~ "no wireless extensions" ]]
	then
		echo "[->] Listen on $(psuc $iface_in) @ $(psuc $iprouter)"
	else
		apn=$(grep -Po '(?<=^ssid=)[^ ]*' ${listfc[hostapd]})
		apw=$(grep -Po '(?<=wpa_passphrase=)[^ ]*' ${listfc[hostapd]})
		echo "[->] AP listen on $(psuc $iface_in) @ $(psuc $iprouter)"
		echo "[->] AP name: $(psuc $apn)"
		echo "[->] AP password: $(psuc $apw)"
	fi
	echo "[->] Client subnet ip-range available: $(psuc $iprl) - $(psuc $iprh)"
	echo ""
	echo "[->] TRAFFIC ROUTE:   $(psuc \=\=\>) $iface_in $(perr \=\=\>) $iface_out $(perr \=\=\>)"
	echo "*****************************************************************************"
	echo ""
}

# setup router mode
function setupRM(){
	# check if already started
	if [[ $(sysctl net.ipv4.ip_forward | awk '{print $3}') -eq 1 ]] || [[ -f "/etc/dhcpcd.conf.preRM" ]] || [[ -f "/etc/hostapd/hostapd.conf.preRM" ]] || [[ -f "/etc/dnsmasq.conf.preRM" ]]
	then
		echo "==> RouterMode "$(psuc "already")" Started !"
		echo ""
		for srv in ${!listfc[@]}
		do
			if [[ ! $(systemctl is-active $srv |grep -w 'active') ]]
			then
				echo $(perr "WARNING:")" service '$srv' is inactive! RouterMode may not work. Start it manually. Ignore error if input interface is ethernet."
			fi
		done			
		getInfo
		while :
		do
			read -p "Do you want change config? (y|n) "
			if [[ $REPLY =~ ^(y|Y) ]]
			then
				ecfg=1
				break
			elif [[ $REPLY =~ ^(n|N) ]]
			then
				echo ""
				exit 0
			fi
		done
	fi
	
	if [[ $ecfg -ne 1 ]]
	then
		checkRequirements
	fi
	# list iface
	echo "[*] Search interfaces..."
	iface_av=($(ip -br a | grep -vw 'lo' | awk '{print $1}'))
	if [[ ${#iface_av[@]} -eq 0 ]]
	then
		echo $(perr "[-]") "No interfaces found!"
		exit 0
	else
		echo $(psuc "[+]") "Found:"
	fi
	
	for i in ${!iface_av[@]}
	do
		echo -e "\t-> ${iface_av[$i]}"
	done
	
	# select iface
	echo ""
	while :
	do
		read -p "> Traffic $(psuc input) interface: " iface_in
		iface_in=${iface_in% *}
		if [[  ${iface_av[@]} =~ (^| )$iface_in( |$) ]]
		then
			# flag for ethernet iface
			if [[ "$(iwconfig $iface_in 2>&1 | awk '{print $2,$3,$4}')" =~ "no wireless extensions" ]]
			then
				ifaceEth=1
			fi
			break
		else
			echo $(pwarn "Interface not exist")
		fi
	done
	while :
	do
		read -p "> Traffic $(perr output) interface: " iface_out
		iface_out=${iface_out% *}
		if [[  ${iface_av[@]} =~ (^| )$iface_out( |$) ]]
		then
			if [[ "$iface_out" == "$iface_in" ]]
			then
				echo $(pwarn "INPUT and OUTPUT interface cannot be same")
			else
				break
			fi
		else
			echo $(pwarn "Interface not exist")
		fi
	done
	echo ""
	
	# change config file: check if config already exists, if not write from scratch
	# case iface_in is wlan verify hostapd
	echo -n "[*] check if services already configured... "
	if [[ $ifaceEth -eq 1 ]]
	then
		if [[ -f ${listfc[dnsmasq]}.preAVM && -f ${listfc[dhcpcd]}.preAVM ]] || [[ -f ${listfc[dnsmasq]}.preRM && -f ${listfc[dhcpcd]}.preRM ]]
		then
			echo $(psuc "YES")
			isConfig=1
		else
			echo $(psuc "NO")
			isConfig=0
		fi
	else
		if [[ -f ${listfc[dnsmasq]}.preAVM && -f ${listfc[dhcpcd]}.preAVM ]] || [[ -f ${listfc[dnsmasq]}.preRM && -f ${listfc[dhcpcd]}.preRM ]]
		then
			# check hostapd here to solve problem file .preAVM not found if installed for the first time with apvncmode script
			if [[ -f ${listfc[hostapd]}.preAVM ]] || [[ -f ${listfc[hostapd]}.preRM ]]
			then
				echo $(psuc "YES")
				isConfig=1
			else
				if [[ -f ${listfc[hostapd]} ]]
				then
					echo $(psuc "Found")
					echo $(pwarn "[?]") "Found 'hostapd.conf' configuration file, but not sure it's right. What to do?"
					echo "1) Keep current"
					echo "2) Configure new AP"
					echo ""
					while :
					do
						read -p "> "
						if [[ $REPLY -eq 1 ]]
						then
							echo $(psuc "[+]") "keep current config..."
							isConfig=1
							break
						elif [[ $REPLY -eq 2 ]]
						then
							echo $(psuc "[+]") "new AP will be configured..."
							isConfig=0
							break
						fi
					done
				else
					echo $(psuc "NO")
					isConfig=0
				fi
			fi
		else
			echo $(psuc "NO")
			isConfig=0
		fi
	fi
		
	# if no config, require params
	if [[ $isConfig -eq 1 ]]
	then
		:		
	else
		# ask network config
		echo "[*] Network configuration:"
		if [[ $ifaceEth -eq 1 ]]
		then
			# if iface_in = eth skip ap conf
			:
		else
			# get ap ssid + pwd
			echo -ne "\t"
			read -p "Insert AP ssid name: " apName
			while :
			do
				echo -ne "\t"
				read -p "Insert AP password: " apPwd
				if [[ ${#apPwd} -lt 8 || ${#apPwd} -gt 60 ]]
				then
					echo -ne "\t"
					echo $(pwarn "Password length must be between 8-60")
				else
					break
				fi
			done
		fi
		# get subnet
		while :
		do
			echo -ne "\t"
			read -p "IP subnet (eg: 192.168.10.0 or 10.10.10.0): " apSub
			if validIp $apSub
			then
				break
			else
				echo -en "\t"
				echo $(perr "$apSub is not valid IP!")
			fi
		done
		# get range
		while :
		do
			echo -ne "\t"
			read -p "IP range subnet (eg: 5-55): " apRange
			apRangeStart=${apRange%-*}
			apRangeEnd=${apRange#*-}
			if [[ $apRangeStart -gt 1 ]] && [[ $apRangeStart -lt 255 ]] && [[ $apRangeEnd -gt 1 ]] && [[ $apRangeEnd -lt 255 ]]
			then
				break
			else
				echo -ne "\t"
				echo $(perr "$apRange is not valid! Numbers 1 and 255 are reserved. Use this form: START-END")
			fi
		done
	fi

	# edit config
	for fc in ${!listfc[@]}
	do
		# if iface is ethernet then skip config hostapd
		if [[ "$fc" == "hostapd" ]] && [[ $ifaceEth -eq 1 ]]
		then
			:
		else
			echo "[*] configure $fc"
			# if want edit pre-existent config, no backup
			if [[ $ecfg -eq 1 ]]
			then
				:
			else
				if [[ -f ${listfc[$fc]} ]]
				then
					echo -ne "\t...backup file @ '${listfc[$fc]}.preRM'... "
					cp ${listfc[$fc]}{,.preRM}
					echo $(psuc "Done")
				else
					echo $(perr "Error: file '${listfc[$fc]}' not found. Cannot continue")
					exit 0
				fi
			fi
			echo -e "\n--- configure file: '${listfc[$fc]}' ---\n" >>$LOGFD
			echo -ne "\t...configure '${listfc[$fc]}' file... "
			# if configured by script ApVncMode change only iface else write all file 
			if [[ $isConfig -eq 1 ]]
			then
				if [[ "$fc" == "dhcpcd" ]]
				then
					if sed -i "s/^interface.*/interface $iface_in/" ${listfc[$fc]} &>>$LOGFD
					then
						# case wifiAP and nohook not set
						if [[ ! $(grep "nohook wpa_supplicant" ${listfc[$fc]}) ]]
						then
							echo "    nohook wpa_supplicant" >> ${listfc[$fc]}
						else
							# case nohook is comment 
							sed -i -e "/nohook wpa_supplicant/s/^#//" ${listfc[$fc]} &>>$LOGFD
						fi
						if [[ $ifaceEth -eq 1 ]]
						then
							# remove "nohook wpa_supplicant"
							if sed -i -e "/nohook wpa_supplicant/s/^#*/#/" ${listfc[$fc]} &>>$LOGFD
							then
								echo $(psuc "Done")
							else
								echo $(perr "Error. Check logs @ '$LOGFD'")
							fi
						else
							echo $(psuc "Done")
						fi
					else
						echo $(perr "Error. Check logs @ '$LOGFD'")
					fi
				else
					if sed -i "s/^interface=.*/interface=$iface_in/" ${listfc[$fc]} &>>$LOGFD
					then
						echo $(psuc "Done")
					else
						echo $(perr "Error. Check logs @ '$LOGFD'")
					fi
				fi
			else
				# manual config
				case $fc in
					hostapd)
						# retrive country_code
						cc=$(grep -iw country /etc/wpa_supplicant/wpa_supplicant.conf | cut -d'=' -f2)
						if [[ -z "$cc" ]] ; then cc="US" ; fi
						echo -e "### CUSTOM CONFIG BY ROUTERMODE SCRIPT ###\n"\
"country_code=$cc\n"\
"interface=$iface_in\n"\
"ssid=$apName\n"\
"hw_mode=g\n"\
"channel=7\n"\
"macaddr_acl=0\n"\
"auth_algs=1\n"\
"ignore_broadcast_ssid=0\n"\
"wpa=2\n"\
"wpa_passphrase=$apPwd\n"\
"wpa_key_mgmt=WPA-PSK\n"\
"wpa_pairwise=TKIP\n"\
"rsn_pairwise=CCMP" > /etc/hostapd/hostapd.conf
						echo $(psuc "Done (with default params, you can change them manually)")
						;;
					
					dhcpcd)
						# solves double writing
						if [[ $(grep "### CUSTOM.*ROUTERMODE.*###" ${listfc[dhcpcd]}) ]]
						then
							# replace
							sed -i "s/^interface.*/interface $iface_in/" ${listfc[$fc]}
							sed -i "s/ip_address=.*\//ip_address=${apSub%.*}.1\//" ${listfc[$fc]}
							if [[ ! $(grep "nohook wpa_supplicant" ${listfc[$fc]}) ]]
							then
								echo "    nohook wpa_supplicant" >> /etc/dhcpcd.conf
							fi
							if [[ $ifaceEth -eq 1 ]]
							then
								# remove "nohook wpa_supplicant"
								sed -i -e "/nohook wpa_supplicant/s/^#*/#/" ${listfc[$fc]}
							fi
						else
							# append to exist
							echo -e "\n### CUSTOM CONFIG BY ROUTERMODE SCRIPT ###\n"\
"interface $iface_in\n"\
"    static ip_address=${apSub%.*}.1/24" >> /etc/dhcpcd.conf
							# if iface_in not eth, add nohook wpa..
							if [[ $ifaceEth -ne 1 ]]
							then
								echo "    nohook wpa_supplicant" >> /etc/dhcpcd.conf
							fi
						fi
						echo $(psuc "Done")
						;;
					
					dnsmasq)
						echo -e "interface=$iface_in\n"\
"dhcp-range=${apSub%.*}.$apRangeStart,${apSub%.*}.$apRangeEnd,255.255.255.0,24h\n"\
"listen-address=::1,127.0.0.1,${apSub%.*}.1" > /etc/dnsmasq.conf
						echo $(psuc "Done (with default params, you can change them manually)")
						;;
					*)
						echo $(perr "Something wrong! This service is not handled: $fc ")
						;;
				esac
			fi
		fi
	done
	
	# change network rule
	echo -n "[*] enable traffic forward... "
	echo -e "\n--- traffic rule: enable forward ---\n">>$LOGFD
	if sysctl net.ipv4.ip_forward=1 &>>$LOGFD
	then
		echo $(psuc "Done")
	else
		echo $(perr "Error. Check logs @ '$LOGFD'")
	fi
	echo -n "[*] make traffic forward persistent... "
	echo -e "\n--- traffic rule: save forward ---\n">>$LOGFD
	if (echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/RMrules.conf) &>>$LOGFD
	then
		echo $(psuc "Done")
	else
		echo $(perr "Error. Check logs @ '$LOGFD'")
	fi
	
	echo -n "[*] check iptables rules... "
	echo -e "\n--- traffic rule: add iptables rules ---\n">>$LOGFD
	# avoid duplicating rules
	prevIT=$(iptables -t nat -S | grep -Po '(?<=\-A POSTROUTING \-o ).*(?= \-j MASQUERADE$)')
	if [[ "$prevIT" == "$iface_out" ]]
	then
		# skip add
		echo $(psuc "Done")
	else
		# remove old
		if iptables -t nat -C POSTROUTING -o $prevIT -j MASQUERADE &>>$LOGFD
		then
			echo -n "found old..delete.. "
			if iptables -t nat -D POSTROUTING -o $prevIT -j MASQUERADE &>>$LOGFD
			then
				echo -n $(psuc "Done")
			else
				echo $(perr "Error. Check logs @ '$LOGFD'")
			fi
		fi
		echo -n " ..add new.. "
		if iptables -t nat -A POSTROUTING -o $iface_out -j MASQUERADE &>>$LOGFD
		then
			echo $(psuc "Done")
		else
			echo $(perr "Error. Check logs @ '$LOGFD'")
		fi
	fi
	
	echo -n "[*] make iptables rules persistent... "
	echo -e "\n--- traffic rule: save iptables rules ---\n">>$LOGFD
	if netfilter-persistent save &>>$LOGFD
	then
		echo $(psuc "Done")
	else
		echo $(perr "Error. Check logs @ '$LOGFD'")
	fi
		
	# ask if want change ap conf, if iface = eth -> skip
	if [[ $ifaceEth -ne 1 ]]
	then
		while :
		do
			read -p "[*] Do you want see details about current AP config? (y|n)   "
			if [[ $REPLY =~ ^(y|Y) ]]
			then
				declare -A apParam=()
				if [[ ! -f ${listfc[hostapd]} ]]
				then
					echo $(perr "[!] ERROR: configuration file '${listfc[hostapd]}' not found.")
					break
				fi
				while read -r kk vv
				do
					apParam["$kk"]="$vv"
				done < <(cat  ${listfc[hostapd]} | tr '=' ' ')
				echo ""
				echo "CURRENT AP CONFIG:"
				echo "Iface used: $(psuc ${apParam[interface]})"
				echo "Name: $(psuc ${apParam[ssid]})"
				echo "Wpa Pwd: $(psuc ${apParam[wpa_passphrase]})"
				echo "Channel used: $(psuc ${apParam[channel]})"
				echo "Wifi speed: $(psuc ${apParam[hw_mode]})"
				echo -n "AP hidden: "
				if [[ ${apParam[ignore_broadcast_ssid]} -eq 0 ]] ; then
					echo $(psuc "no")
				else
					echo $(psuc "yes")
				fi
				echo ""
				while :
				do
					read -p "[*] Do you want make changes on this config? (y|n)   "
					if [[ $REPLY =~ ^(y|Y) ]]
					then
						if [[ ! -f  "${listfc[hostapd]}.preRM" ]] ; then
							echo "[*] create backup copy of hostapd.conf => hostapd.conf.preRM"
							echo -e "\n--- change config: hostapd backup conf ---\n">>$LOGFD
							cp  ${listfc[hostapd]}{,.preRM} &>>$LOGFD
							if [[ $? -eq 0 ]] ; then
								echo $(psuc "[+]") "Done"
							else
								echo $(perr "[-]") "Error. Check logs @ '$LOGFD'. Continue but restore to previous config may fail"
							fi
						fi
						echo $(pwarn "[ hint: press ENTER to skip/keep param ]")
						echo ""
						for par in "ssid" "wpa_passphrase" "hw_mode" "channel" "ignore_broadcast_ssid"
						do
							read -p "> New $par: "
							ans=${REPLY// /}	# trim
							if [[ $ans ]]
							then
								if [[ $par == "wpa_passphrase" ]] ; then
								while :
								do
									if [[ ${#ans} -lt 8 || ${#ans} -gt 60 ]]
									then
										echo $(pwarn "! Password length must be between 8-60")
										read -p "> New $par: "
										ans=${REPLY// /}
									else
										break
									fi
								done
								fi
								echo -e "\n--- change config: edit hostapd conf ---\n">>$LOGFD
								if sed -i -e "s/^$par=.*/$par=$ans/" ${listfc[hostapd]} &>>$LOGFD
								then
									echo "..changed.."
								else
									echo $(perr "Error. Check logs @ '$LOGFD'")
								fi
							else
								echo "..skipped.."
							fi
						done
						break
					elif [[ $REPLY =~ ^(n|N) ]]
					then
						echo "[*] keep current config"
						break
					fi
				done
				break
			elif [[ $REPLY =~ ^(n|N) ]]
			then
				break
			fi
		done
	fi
	
	# ask if want change dhcp/dns conf
	while :
	do
		read -p "[*] Do you want see details about current DNS config? (y|n)   "
		if [[ $REPLY =~ ^(y|Y) ]]
		then
			declare -A dnsParam=()
			if [[ ! -f ${listfc[dnsmasq]} ]]
			then
				echo $(perr "[!] ERROR: configuration file '${listfc[dnsmasq]}' not found.")
				break
			fi
			# extract params from config
			dnsParam[iface]=$(grep -Po '(?<=interface=)[^ ]*' ${listfc[dnsmasq]})
			dnsParam[iprl]=$(grep -Po '(?<=dhcp-range=)[^ ]*' ${listfc[dnsmasq]} | cut -d',' -f1)
			dnsParam[iprh]=$(grep -Po '(?<=dhcp-range=)[^ ]*' ${listfc[dnsmasq]} | cut -d',' -f2)
			dnsParam[la]=$(grep -Po '(?<=listen-address=)[^ ]*' ${listfc[dnsmasq]} | cut -d',' -f3)
			echo ""
			echo "CURRENT DNS CONFIG:"
			echo "Iface used: $(psuc ${dnsParam[iface]})"
			echo "Listen on: $(psuc ${dnsParam[la]})"
			echo "IP subnet range: $(psuc ${dnsParam[iprl]} - ${dnsParam[iprh]})"
			echo ""
			
			while :
			do
				read -p "[*] Do you want make changes on this config? (y|n)   "
				if [[ $REPLY =~ ^(y|Y) ]]
				then
					if [[ ! -f  "${listfc[dnsmasq]}.preRM" ]] ; then
						echo "[*] create backup copy of dnsmasq.conf => dnsmasq.conf.preRM"
						echo -e "\n--- change config: dnsmasq backup conf ---\n">>$LOGFD
						cp  ${listfc[dnsmasq]}{,.preRM} &>>$LOGFD
						if [[ $? -eq 0 ]] ; then
							echo $(psuc "[+]") "Done"
						else
							echo $(perr "[-]") "Error. Check logs @ '$LOGFD'. Continue but restore to previous config may fail"
						fi
					fi
					if [[ ! -f  "${listfc[dhcpcd]}.preRM" ]] ; then
						echo "[*] create backup copy of dhcpcd.conf => dhcpcd.conf.preRM"
						echo -e "\n--- change config: dhcpcd backup conf ---\n">>$LOGFD
						cp  ${listfc[dhcpcd]}{,.preRM} &>>$LOGFD
						if [[ $? -eq 0 ]] ; then
							echo $(psuc "[+]") "Done"
						else
							echo $(perr "[-]") "Error. Check logs @ '$LOGFD'. Continue but restore to previous config may fail"
						fi
					fi
					echo $(pwarn "[ hint: press ENTER to skip/keep param ]")
					echo ""
					# get new conf
					echo -e "\n--- change config: dnsmasq edit conf ---\n">>$LOGFD 
					# listen address
					while :
					do
						read -p "> New IP: "
						# trim
						ans=${REPLY// /}
						if [[ $ans ]]
						then
							if validIp $ans
							then
								dnsParam[la]="${ans%.*}.1"
								edns=1
								break
							else
								echo $(pwarn "-> Not a valid ip address <-")
							fi
						else
							dnsParam[la]="${dnsParam[la]%.*}.1"
							echo "..skipped.."
							break
						fi
					done
					# ip range
					while :
					do
						read -p "> New subnet range (format 10-55): "
						ans=${REPLY// /}	# trim
						if [[ $ans ]]
						then
							rangeLow=${ans%-*}
							rangeHigh=${ans#*-}
							if [[ $rangeLow -gt 1 ]] && [[ $rangeLow -lt 255 ]] && [[ $rangeHigh -gt 1 ]] && [[ $rangeHigh -lt 255 ]]
							then
								dnsParam[iprl]="${dnsParam[la]%.*}.$rangeLow"
								dnsParam[iprh]="${dnsParam[la]%.*}.$rangeHigh"
								edns=1
								break
							else
								echo $(pwarn "Range not valid! Numbers 1 and 255 are reserved. Use this form: START-END")
							fi
						else
							dnsParam[iprl]="${dnsParam[la]%.*}.${dnsParam[iprl]#*.*.*.}"
							dnsParam[iprh]="${dnsParam[la]%.*}.${dnsParam[iprh]#*.*.*.}"
							echo "..skipped.."
							break
						fi
					done
				
					echo ""
					# update config
					if [[ $edns -eq 1 ]]
					then
						echo -n "[*] update config... "
						err=0
						# update dhcp
						echo -e "\n--- update dhcpcd config ---\n" >>$LOGFD
						if sed -i "s/ip_address=.*\//ip_address=${dnsParam[la]}\//" ${listfc[dhcpcd]} &>>$LOGFD ; then : ; else let "err++" ; fi
						# update dnsmasq
						echo -e "\n--- update dnsmasq config ---\n" >>$LOGFD
						if sed -i -E "s/(listen-address=.*,)(.*)/\1${dnsParam[la]}/" ${listfc[dnsmasq]} &>>$LOGFD ; then : ; else let "err++" ; fi
						if sed -i -E "s/(dhcp-range=)(.*,)(.*,)(.*,+.*)/\1${dnsParam[iprl]},\3\4/" ${listfc[dnsmasq]} &>>$LOGFD ; then : ; else let "err++" ; fi
						if sed -i -E "s/(dhcp-range=)(.*,)(.*,)(.*,+.*)/\1\2${dnsParam[iprh]},\4/" ${listfc[dnsmasq]} &>>$LOGFD ; then : ; else let "err++" ; fi
						# check errors
						if [[ $err -gt 0 ]]
						then
							echo $(perr "Error. Update config fails $err times. Check logs @ '$LOGFD'")
						else
							echo $(psuc "Done")
						fi
					else
						echo "[*] no changes made, keep current config"
					fi					
					break
				elif [[ $REPLY =~ ^(n|N) ]]
				then
					echo "[*] keep current config"
					break
				fi
			done
			break
		elif [[ $REPLY =~ ^(n|N) ]]
		then
			break
		fi
	done
	
	# enable services on boot
	for fc in ${!listfc[@]}
	do
		if [[ "$fc" == "hostapd" ]] && [[ $ifaceEth -eq 1 ]]
		then
			# disable hostapd
			echo -n "[*] disable $fc on boot... "
			echo -e "\n--- disable on boot service: $fc.service ---\n">>$LOGFD
			if systemctl disable $fc &>>$LOGFD
			then
				echo $(psuc "Done")
			else
				echo $(perr "Error. Check logfile @ '$LOGFD'")
			fi
		else
			echo -n "[*] enable $fc on boot... "
			echo -e "\n--- enable on boot service: $fc.service ---\n">>$LOGFD
			if systemctl enable $fc &>>$LOGFD
			then
				echo $(psuc "Done")
			else
				echo $(perr "Error. Check logfile @ '$LOGFD'")
			fi
		fi
	done
	
	# restart services
	# little hack to sort array and restart service in order, to solve problem of ip assignment to iface
	#keys=( $(echo ${!listfc[@]} | tr ' ' $'\n' | sort) )
	for fc in ${!listfc[@]}  #${keys[@]}
	do
		if [[ "$fc" == "hostapd" ]] && [[ $ifaceEth -eq 1 ]]
		then
			# stop hostapd
			echo -n "[*] stop $fc service... "
			echo -e "\n--- stop service: $fc.service ---\n">>$LOGFD
			if systemctl stop $fc &>>$LOGFD
			then
				echo $(psuc "Done")
			else
				echo $(perr "Error. Check logfile @ '$LOGFD'")
			fi
		else
			echo -n "[*] restart $fc service... "
			echo -e "\n--- restart service: $fc.service ---\n">>$LOGFD
			if systemctl restart $fc &>>$LOGFD
			then
				echo $(psuc "Done")
			else
				echo $(perr "Error. Check logfile @ '$LOGFD'")
			fi
			sleep 3
		fi
	done
	
	# clear old ips
	for x in $iface_in $iface_out
	do
		echo -n "[*] clean $x address... "
		echo -e "\n--- clean $x IP address ---\n" >>$LOGFD 
		if ip addr flush dev $x &>>$LOGFD
		then
			echo $(psuc "Done")
		else
			echo $(perr "Error. Check logfile @ '$LOGFD'")
		fi
		sleep 3
		echo -n "[*] raise up $x ... "
		echo -e "\n--- raise up $x  ---\n" >>$LOGFD 
		if ip link set dev $x up &>>$LOGFD
		then
			echo $(psuc "Done")
		else
			echo $(perr "Error. Check logfile @ '$LOGFD'")
		fi
		sleep 3
	done
		
	# show recap, retrieve info again because if user skip config these will not be retrieved
	echo $(pwarn "[!] REMEMBER: current RouterMode configuration will persist upon reboot")
	echo -e $(pwarn "\t\tuntil you give the command: \e[3m'$(basename $0) stop'\e[0")
	echo -e $(pwarn "[HINT] \e[3mif you have problem with correct IP assignment\n\ttry disconnect-and-reattch ethernet cable or try reboot\e[0")
	getInfo
}

# restore all
function cleanRM(){
	# check if script started
	if [[ $(sysctl net.ipv4.ip_forward | awk '{print $3}') -eq 0 ]] || [[ ! -f "/etc/dhcpcd.conf.preRM" ]] || [[ ! -f "/etc/dnsmasq.conf.preRM" ]]
	then
		echo $(perr "==> RouterMode not Started !")
		echo ""
		exit 0
	fi
		
	# retrive interface output for iptables
	# search through same rule applied
	iface_out=$(iptables -t nat -S | grep -Po '(?<=\-A POSTROUTING \-o ).*(?= \-j MASQUERADE$)')
	
	# restore config files
	for fc in ${!listfc[@]}
	do
		echo -e "\n--- cleanRM: restore $fc config file ---\n">>$LOGFD
		echo -n "[*] restore $fc configuration... "
		if [[ -f "${listfc[$fc]}.preRM" ]]
		then
			if mv ${listfc[$fc]}.preRM ${listfc[$fc]} &>>$LOGFD
			then
				echo $(psuc "Done")
			else
				echo $(perr "Error. Check logs @ '$LOGFD'")
			fi
		else
			# case interface was ethernet AP was not set, so not file exist
			if [[ "$fc" == "hostapd" ]]
			then
				echo $(pwarn "File '${listfc[$fc]}' not found!")"..."$(psuc "Skip")
			else
				echo $(perr "Error: file '${listfc[$fc]}' not found!")
			fi
		fi
	done
	
	# disable traffic forward
	echo -e "\n--- cleanRM: disable traffic forward ---\n">>$LOGFD
	echo -n "[*] disable traffic forward... "
	if sysctl net.ipv4.ip_forward=0 &>>$LOGFD
	then
		echo $(psuc "Done")
	else
		echo $(perr "Error. Check logs @ '$LOGFD'")
	fi
	echo -e "\n--- cleanRM: remove traffic forward persistent rules ---\n">>$LOGFD
	echo -n "[*] remove traffic forward persistent rules... "
	if [[ -f "/etc/sysctl.d/RMrules.conf" ]]
	then
		if rm /etc/sysctl.d/RMrules.conf &>>$LOGFD
		then
			echo $(psuc "Done")
		else
			echo $(perr "Error. Check logs @ '$LOGFD'")
		fi
	else
		echo $(perr "Error. Check logs @ '$LOGFD'")
	fi
	
	# restore iptables rules
	echo -e "\n--- cleanRM: restore iptables rules ---\n">>$LOGFD
	echo -n "[*] remove iptables rules... "
	if iptables -t nat -C POSTROUTING -o $iface_out -j MASQUERADE &>>$LOGFD
	then
		if iptables -t nat -D POSTROUTING -o $iface_out -j MASQUERADE &>>$LOGFD
		then
			echo $(psuc "Done")
		else
			echo $(perr "Error. Check logs @ '$LOGFD'")
		fi
	else
		echo $(perr "Error. Rule not found! Check logs @ '$LOGFD'")
	fi
	echo -e "\n--- cleanRM: disable iptables persistent rules ---\n">>$LOGFD
	echo -n "[*] remove iptables persistent rules... "
	if netfilter-persistent save &>>$LOGFD
	then
		echo $(psuc "Done")
	else
		echo $(perr "Error. Check logs @ '$LOGFD'")
	fi
	
	# disable services on boot
	# dhcpcd: remains always active
	# dnsmasq: check config, if found iface uncommented then leave enabled
	# hostapd: if dnsmasq active and iface equal in both config, leave enabled
	echo -n "[*] try to gather info about previous behavior... "
	declare -a srvToRestore
	srvToRestore+=("dhcpcd")
	prevIface=$(grep -Po "(?<=^interface=)[^ ]*" ${listfc[dnsmasq]} 2>>$LOGFD)
	# check dnsmasq
	if [[ $prevIface ]]
	then
		# check hostapd
		apIface=$(grep -Po "(?<=^interface=)[^ ]*" ${listfc[hostapd]} 2>>$LOGFD)
		if [[ $apIface ]] && [[ "$apIface" == "$prevIface" ]]
		then
			# AP full: dnsmasq + hostapd
			srvToRestore+=("dnsmasq" "hostapd")
			echo $(psuc "Done")
		else
			# AP on ethernet: only dnsmasq
			srvToRestore+=("dnsmasq")
			echo $(psuc "Done")
			echo -n "[*] stop hostapd service... "
			echo -e "\n--- stop service: hostapd.service ---\n">>$LOGFD
			if systemctl stop hostapd &>>$LOGFD
			then
				echo $(psuc "Done")
			else
				echo $(perr "Error. Check logfile @ '$LOGFD'")
			fi
			echo -n "[*] disable hostapd service on boot... "
			echo -e "\n--- disable service: hostapd.service ---\n">>$LOGFD
			if systemctl disable hostapd &>>$LOGFD
			then
				echo $(psuc "Done")
			else
				echo $(perr "Error. Check logfile @ '$LOGFD'")
			fi
		fi
	else
		echo $(psuc "Done")
		# NO AP: only dhcpcd
		for srv in hostapd dnsmasq
		do
			echo -n "[*] stop $srv service... "
			echo -e "\n--- stop service: $srv.service ---\n">>$LOGFD
			if systemctl stop $srv &>>$LOGFD
			then
				echo $(psuc "Done")
			else
				echo $(perr "Error. Check logfile @ '$LOGFD'")
			fi
			echo -n "[*] disable $srv service on boot... "
			echo -e "\n--- disable service: $srv.service ---\n">>$LOGFD
			if systemctl disable $srv &>>$LOGFD
			then
				echo $(psuc "Done")
			else
				echo $(perr "Error. Check logfile @ '$LOGFD'")
			fi
		done
	fi
	
	
	# restart services
	for srv in ${srvToRestore[@]}
	do
		echo -n "[*] restart $srv service... "
		echo -e "\n--- restart service: $srv.service ---\n">>$LOGFD
		if systemctl restart $srv &>>$LOGFD
		then
			echo $(psuc "Done")
		else
			echo $(perr "Error. Check logfile @ '$LOGFD'")
		fi
		sleep 3
	done

	# clear old ips
	echo -n "[*] clean old ip address... "
	echo -e "\n--- clean old IP address ---\n" >>$LOGFD 
	if ip addr flush up &>>$LOGFD
	then
		echo $(psuc "Done")
	else
		echo $(perr "Error. Check logfile @ '$LOGFD'")
	fi
	sleep 3
	
	echo ""
	echo $(psuc "[+] ALL CLEAN! If no error raised device behavior should be restored.")
	echo ""
}

# show info
function helper(){
	tput setaf 3
	echo "The purpose of this script is to quickly configure the device as a router to facilitate"
	echo "traffic analysis operations, but it can also be used like a normal AP-router."
	echo "It takes 2 interfaces and redirects traffic from one to the other."
	echo "Designed for RPI, but it should work on all linux device."
	echo "Example:"
	echo "*  device -> trafficIN (wlan0 rpi) -> trafficOUT (wlan1 rpi) -> home-router (wifi)"
	echo "*  device -> trafficIN (wlan0 rpi) -> trafficOUT (eth0 rpi) -> home-router (cable)"
	echo "*  device -> trafficIN (eth0 rpi) -> trafficOUT (wlanX rpi) -> home-router (wifi)"
	tput sgr0
	echo ""
	echo "Usage: $0  <start|stop>"
	echo "" 
}

# main
# banner
echo " ____             _            __  __           _      "
echo "|  _ \ ___  _   _| |_ ___ _ __|  \/  | ___   __| | ___ "
echo "| |_) / _ \| | | | __/ _ \ '__| |\/| |/ _ \ / _\` |/ _ \\"
echo "|  _ < (_) | |_| | ||  __/ |  | |  | | (_) | (_| |  __/"
echo "|_| \_\___/ \__,_|\__\___|_|  |_|  |_|\___/ \__,_|\___|"
echo ""
echo $(pwarn "DISCLAIMER: use this script at your own risk !")
echo ""

if [[ $(id -u) -ne 0 ]]
then
	echo $(perr "This script must be run as root.")
	echo ""
	exit 0
fi

if [[ $# != 1 ]] ; then
	helper
	exit 0
else
	case "$1" in
		start)
			setupRM
			exit 0
			;;
		stop)
			cleanRM
			exit 0
			;;
		*)
			helper
			exit 0
			;;
	esac
fi
