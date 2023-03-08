#!/bin/bash

# global
LOGFD="apvncmode.log"

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

# check requirements
function checkRequirements(){
	export DEBIAN_FRONTEND=noninteractive
	declare -a reqPkg
	
	echo "[*] Check required packages..."
	# case ap+vnc add search of vnc package
	if [[ $# -eq 1 ]] && [[ $@ == "APVNC" ]]
	then
		echo -e "\n--- find vncserver pkg ---\n" >>$LOGFD
		if dpkg --get-selections realvnc-vnc-server 2>>$LOGFD | grep -iw "install" &>>$LOGFD
		then
			echo "$(psuc [+]) realvnc-vnc-server already installed"
			vncType="real"
		else
			echo "$(perr [-]) realvnc-vnc-server not installed"
			echo "... check other types of VncServer ..."
			if dpkg --get-selections tightvncserver 2>>$LOGFD | grep -iw "install" &>>$LOGFD
			then
				echo "$(psuc [+]) tightvncserver already installed"
				vncType="tight"
			else
				echo "$(perr [-]) tightvncserver not installed"
				echo "[?] which VncServer do you want?"
				echo "1) realvnc"
				echo "2) tightvnc"
				while :
				do
					read -p "> "
					if [[ $REPLY -eq 1 ]]
					then
						reqPkg+=("realvnc-vnc-server")
						echo "$(psuc [+]) realvnc will be installed"
						vncType="real"
						break
					elif [[ $REPLY -eq 2 ]]
					then
						reqPkg+=("tightvncserver")
						echo "$(psuc [+]) tightvnc will be installed"
						vncType="tight"
						break
					fi
				done
			fi
		fi
	fi
	# search ap packages
	for p in hostapd dnsmasq
	do
		echo -e "\n--- find $p pkg ---\n" >>$LOGFD
		dpkg-query -W -f='${Status}' $p 2>>$LOGFD | grep -iw 'install' &>>$LOGFD
		if [[ $? -eq 0 ]]
		then
			echo "$(psuc [+]) $p already installed"
		else
			echo "$(perr [-]) $p not installed"
			reqPkg+=("$p")
		fi
	done
	
	if [[ ${#reqPkg[@]} -ne 0 ]]
	then
		while :
		do
			read -p "Install missing packages? [Y/n] "
			if [[ $REPLY =~ ^(y|Y) ]] || [[ -z $REPLY ]]
			then
				echo -n "[*] update repository... "
				echo -e "\n--- update repository ---\n" >>$LOGFD
				if apt-get -y update &>>$LOGFD
				then
					echo "$(psuc Done)"
				else
					echo $(perr "Error. Check logfile @ '$LOGFD'")
					exit 0
				fi
				echo -n "[+] install packages... "
				echo -e "\n--- install packages: ${reqPkg[@]} ---\n" >>$LOGFD
				if apt-get -y install ${reqPkg[@]} &>>$LOGFD
				then
					echo "$(psuc Done)"
					break
				else
					echo $(perr "Error. Check logfile @ '$LOGFD'")
					exit 0
				fi
			elif [[ $REPLY =~ ^(n|N) ]]
			then
				echo $(pwarn "[!] The following packages are required to continue:")
				for p in ${reqPkg[@]}
				do
					echo $(pwarn "> $p")
				done
				echo $(pwarn "Install them manually or re-run this scipt.")
				exit 0
			fi
		done
	else
		echo "$(psuc [+]) packages ok... continue"
	fi
}

# validate ip
function validIp(){
	ip=$1
	if [[ "$ip" =~ ^(([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))\.){3}([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))$ ]]
	then
		return 0
	else
		return 1
	fi
}

# setup AP conf
function setupAp(){
	# get param for the net conf
	echo -e "\n==> Network configuration:\n"
	read -p "Insert AP ssid name: " apName
	while :
	do
		read -p "Insert AP password for client connection: " apPwd
		if [[ ${#apPwd} -lt 8 || ${#apPwd} -gt 60 ]]
		then
			echo $(pwarn "! Password length must be between 8-60")
		else
			break
		fi
	done
	while :
	do
		read -p "IP subnet AP client (eg: 192.168.10.0 or 10.10.10.0): " apSub
		if validIp $apSub
		then
			break
		else
			echo $(perr "$apSub is not valid IP!")
		fi
	done
	while :
	do
		read -p "IP range AP will assign to client (eg: 5-55): " apRange
		apRangeStart=${apRange%-*}
		apRangeEnd=${apRange#*-}
		if [[ $apRangeStart -gt 1 ]] && [[ $apRangeStart -lt 255 ]] && [[ $apRangeEnd -gt 1 ]] && [[ $apRangeEnd -lt 255 ]]
		then
			break
		else
			echo $(perr "$apRange is not valid! Numbers 1 and 255 are reserved. Use this form: START-END")
		fi
	done
	echo "Interfaces found on device:"
	if_lst=($(ip -br a | grep -vwi 'lo' | awk '{print $1}'))
	for i in ${if_lst[@]}
	do
		echo "- $i"
	done
	while :
	do
		flag=false
		read -p "Interface where DHCP server will serve requests (eg: wlan0): " iface
		if [[ "$(iwconfig $iface 2>&1 | awk '{print $2,$3,$4}')" =~ "no wireless extensions" ]]
		then
			echo $(perr "Error: AP cannot be set on a ETHERNET interface")
		else
			for i in ${if_lst[@]}
			do
				if [[ $i == $iface ]]
				then
					flag=true
					break
				else
					flag=false
				fi
			done
			if $flag
			then
				break
			else
				echo $(perr "Error: unknown interface")
			fi
		fi
	done		
	
	# setup dhcp conf
	echo "[*] configure dhcp server..."
	if [[ -f /etc/dhcpcd.conf ]]
	then
		cp /etc/dhcpcd.conf{,.preAVM}
	fi
	echo -ne "\t...configure 'dhcpcd.conf' file... "
	echo -e "\n\n### CUSTOM CONFIG FOR AP MODE BY APVNCSCRIPT ###\n"\
"interface $iface\n"\
"    static ip_address=${apSub%.*}.1/24\n"\
"    nohook wpa_supplicant" >> /etc/dhcpcd.conf
	echo $(psuc "Done")
	
	echo -ne "\t...configure dnsmasq... "
	if [[ -f /etc/dnsmasq.conf ]]
	then
		cp /etc/dnsmasq.conf{,.preAVM}
	else
		echo -n $(pwarn "File '/etc/dnsmasq.conf' not found. Try to continue anyway... ")
	fi
	echo -e "interface=$iface\n"\
"dhcp-range=${apSub%.*}.$apRangeStart,${apSub%.*}.$apRangeEnd,255.255.255.0,24h\n"\
"listen-address=::1,127.0.0.1,${apSub%.*}.1" > /etc/dnsmasq.conf
	echo $(psuc "Done")
	
	echo -ne "\t...check rfkill block on AP interface... "
	if [[ $(rfkill | grep ${iface:0:3} | awk '{print $4=="blocked" || $5=="blocked"}') -eq 1 ]]
	then
		echo -n "$(perr blocked) ...try to unblock... "
		if $(rfkill unblock ${iface:0:3})
		then
			echo $(psuc "Done")
		else
			echo $(perr "Error. Try manually. $iface still blocked")
		fi
	else
		echo $(psuc "ok, unblocked")
	fi
	
	# setup hostapd conf
	echo "[*] configure hostapd... "
	if [[ -f /etc/hostapd/hostapd.conf ]]
	then
		cp /etc/hostapd/hostapd.conf{,.preAVM}
	else
		echo -e $(pwarn "\t...file '/etc/hostapd/hostapd.conf' not found. Try to continue anyway... ")
	fi
	echo -ne "\t...check country code... "
	res=$(grep -iw country /etc/wpa_supplicant/wpa_supplicant.conf | cut -d'=' -f2)
	if [[ -z "$res" ]]
	then
		res=$(locale | grep -w LANG | sed "s/^.*_\(\S*\)\..*$/\1/")
		if [[ -z "$res" ]]
		then
			res=$(locale | grep -w LC_ALL | sed "s/^.*_\(\S*\)\..*$/\1/")
			if [[ -z "$res" ]]
			then
				echo -n $(pwarn "Unable to retrieve country from locale... ")
				res="US"
				echo $(psuc "Set default 'US'")
			else
				echo $(psuc "Done")
			fi
		else
			echo $(psuc "Done")
		fi
	else
		echo $(psuc "Done")
	fi
	echo -ne "\t...configure 'hostapd.conf' file... "
	echo -e "### CUSTOM CONFIG FOR AP MODE BY APVNCMODE SCRIPT ###\n"\
"country_code=$res\n"\
"interface=$iface\n"\
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
	echo $(psuc "Done")
		
	# start service
	echo -n "[*] check hostapd service... "
	if res=$(systemctl list-unit-files --state=masked | grep hostapd)
	then
		echo -n "$(perr Masked)...try unmask... "
		echo -e "\n--- unmask hostapd.service ---\n" >> $LOGFD
		if res=$(systemctl unmask hostapd &>>$LOGFD)
		then
			echo $(psuc "Done")
		else
			echo $(perr "Error. Try manually. 'hostapd.service' still masked")
		fi
	else
		echo $(psuc "Done")
	fi

	echo -n "[*] check dnsmasq service... "
	if res=$(systemctl list-unit-files --state=masked | grep dnsmasq)
	then
		echo -n "$(perr Masked)...try unmask... "
		echo -e "\n--- unmask dnsmasq.service ---\n" >> $LOGFD
		if res=$(systemctl unmask dnsmasq &>>$LOGFD)
		then
			echo $(psuc "Done")
		else
			echo $(perr "Error. Try manually. 'dnsmasq.service' still masked")
		fi
	else
		echo $(psuc "Done")
	fi
	
	# service on boot
	echo -e "\nDo you want AP services start on boot? (y/n)"
	while :
	do
		read -p "> "
		if [[ $REPLY =~ ^(y|Y) ]]
		then
			echo -n "[*] enable hostapd on boot... "
			echo -e "\n--- enable hostapd.service ---\n" >> $LOGFD
			if systemctl is-enabled hostapd &>>$LOGFD
			then
				echo $(psuc "Done")
			else
				if systemctl enable hostapd &>>$LOGFD
				then
					echo $(psuc "Done")
				else
					echo $(perr "Error. Try manually. 'hostapd.service' probably won't start on boot")
				fi
			fi
			echo -n "[*] enable dnsmasq at boot... "
			echo -e "\n--- enable dnsmasq.service ---\n" >> $LOGFD
			if systemctl is-enabled dnsmasq &>>$LOGFD
			then
				echo $(psuc "Done")
			else
				if systemctl enable dnsmasq &>>$LOGFD
				then
					echo $(psuc "Done")
				else
					echo $(perr "Error. Try manually. 'dnsmasq.service' probably won't start on boot")
				fi
			fi
			apBoot=1
			break
		elif [[ $REPLY =~ ^(n|N) ]]
		then
			apBoot=0
			echo "[*] check services status..."
			for p in hostapd dnsmasq
			do
				echo -e "\n--- disable $p.service ---\n" >> $LOGFD
				echo -ne "\t...disable $p... "
				if systemctl is-enabled $p &>>$LOGFD
				then
					if systemctl disable $p &>>$LOGFD
					then
						echo $(psuc "Done")
					else
						echo $(perr "Error: $p still enabled ")
					fi
				else
					echo $(psuc "Done")
				fi
			done
			echo $(pwarn "[!] You have chosen a standalone AP. At the next boot AP services will not be started!")
			echo $(pwarn "[!] REMEMBER: if at next boot you have issue with wifi, re-run this script and select 'restoreAll' to restore 'normal' wifi behavior")
			break
		fi
	done
	c=0
	while :
	do
		echo ""
		echo "==> TEST: can you connect to this AP ($(psuc $apName)) with other device (ping/ssh/etc) ?  (y|n)"
		read -p "> "
		if [[ $REPLY =~ ^(y|Y) ]]
		then
			break
		elif [[ $REPLY =~ ^(n|N) ]]
		then
			if [[ $c -eq 1 ]]
			then
				echo -n "[*] try reload dchpcd... "
				echo -e "\n--- reload config and service of dhcpcd.service ---\n" >>$LOGFD
				if systemctl restart dhcpcd &>>$LOGFD
				then
					echo $(psuc "Done")
				else
					echo $(perr "Error. Check logfile @ '$LOGFD'")
				fi
			fi
			echo -n "[*] try reload hostapd... "
			echo -e "\n--- reload config and service of hostapd.service ---\n" >>$LOGFD
			if systemctl restart hostapd &>>$LOGFD
			then
				echo $(psuc "Done")
			else
				echo $(perr "Error. Check logfile @ '$LOGFD'")
			fi
			echo -n "[*] try reload dnsmasq... "
			echo -e "\n--- reload config and service of dnsmasq.service ---\n" >>$LOGFD
			if systemctl restart dnsmasq &>>$LOGFD
			then
				echo $(psuc "Done")
			else
				echo $(perr "Error. Check logfile @ '$LOGFD'")
			fi
			let "c++"
			if [[ $c -eq 2 ]] ; then
				echo -e "\n=> Try to reconnect now. If it still doesn't work, try restart services or check config files manually.\n"
				break			
			fi
		fi
	done
}

# setup vnc
function setupVnc(){
	echo "==> VNC configuration"
	user=$(users | awk '{print $1}')
	echo "Do you want VNC listen only on $iface? (y/n)"
	while :
	do
		read -p "> "
		if [[ $REPLY =~ ^(y|Y) ]]
		then
			vnclif=1
			break
		elif [[ $REPLY =~ ^(n|N) ]]
		then
			vnclif=0
			break
		fi
	done
	
	if [[ "$vncType" == "real" ]]
	then
		echo "What type of view do you want?"
		echo "1) physical / display :0  (same as/if monitor attached)"
		echo "2) virtual  / display :1"
		echo ""
		while :
		do
			read -p "> " vncType2
			if [[ $vncType2 -eq 1 ]]
			then
				echo -e "\n--- start vncserver-x11 as service at display :0---\n" >>$LOGFD
				# listen iface not settable
				echo -n "[*] start vncserver as service @ port 5900... "
				if systemctl start vncserver-x11-serviced &>>$LOGFD
				then
					echo $(psuc "Done!")
				else
					echo $(perr "Error. Check logs @ '$LOGFD'")
				fi
				break
			elif [[ $vncType2 -eq 2 ]]
			then
				echo -e "\n--- start vncserver virtual in userMode at display :1 ---\n" >>$LOGFD
				# check if user want restrict access to iface
				if [[ $vnclif -eq 1 ]]
				then
					echo -n "[*] start vncserver @ $iface:5901... "
					# IpClientAddresses is a workaround of a not working IpListenAddresses
					if sudo -u $user vncserver IpListenAddresses=${apSub%.*}.1 IpClientAddresses=+${apSub%.*}.1/24 -nolisten tcp &>>$LOGFD
					then
						echo $(psuc "Done!")
					else
						echo $(perr "Error. Check logs @ '$LOGFD'")
					fi
					break
				else
					echo -n "[*] start vncserver @ port 5901... "
					if sudo -u $user vncserver -nolisten tcp &>>$LOGFD
					then
						echo $(psuc "Done!")
					else
						echo $(perr "Error. Check logs @ '$LOGFD'")
					fi
					break
				fi
			fi
		done
	elif [[ "$vncType" == "tight" ]]
	then
		echo -e "\n--- start vncserver virtual in userMode at display :1 ---\n" >>$LOGFD
		# check if user want restrict access to iface
		if [[ $vnclif -eq 1 ]]
		then
			echo -n "[*] start vncserver @ $iface:5901... "
			if sudo -u $user vncserver -interface ${apSub%.*}.1 -nolisten tcp &>>$LOGFD
			then
				echo $(psuc "Done!")
			else
				echo $(perr "Error. Check logs @ '$LOGFD'")
			fi
		else
			echo -n "[*] start vncserver @ port 5901... "
			if sudo -u $user vncserver -nolisten tcp &>>$LOGFD
			then
				echo $(psuc "Done!")
			else
				echo $(perr "Error. Check logs @ '$LOGFD'")
			fi
		fi
	fi
	
	echo $(pwarn "[*] Now to ensure all fine, you should try to connect to this device through a remote vncviewver tool.")
	echo -e "\nDo you see remote desktop correct? (y/n)"
	while :
	do
		read -p "> "
		if [[ $REPLY =~ ^(y|Y) ]]
		then
			break
		elif [[ $REPLY =~ ^(n|N) ]]
		then
			echo -e "\n--- try resolve desktop errors ---\n" >>$LOGFD
			# case realvncserver 
			if [[ "$vncType" == "real" ]]
			then
				# case display :0
				if [[ $vncType2 -eq 1 ]]
				then
					for vr in "1024x768" "1920x1080"
					do
						echo -n "[*] change vnc resolution to $vr... "
						if raspi-config nonint do_vnc_resolution $vr &>>$LOGFD
						then
							echo $(psuc Done)
						else
							echo $(perr "Error. Check logs @ '$LOGFD'")
						fi
						echo -n "[*] reload vnc config... "
						if systemctl reload vncserver-x11-serviced &>>$LOGFD
						then
							echo $(psuc Done)
						else
							echo $(perr "Error. Check logs @ '$LOGFD'")
						fi
						echo -n "[*] restart vnc service... "
						if systemctl restart vncserver-x11-serviced &>>$LOGFD
						then
							echo $(psuc Done)
						else
							echo $(perr "Error. Check logs @ '$LOGFD'")
						fi
						echo ""
						c=0
						while :
						do
							read -p $(pwarn "Try reconnect. OK now? (y/n) ")
							if [[ $REPLY =~ ^(y|Y) ]]
							then
								desk_state=1
								break
							elif [[ $REPLY =~ ^(n|N) ]]
							then
								if [[ $c -gt 0 ]]
								then
									# skip to next resolution
									break
								fi
								echo -n "[*] change xrandr resolution to $vr... "
								if xrandr -d :0 --fb $vr &>>$LOGFD
								then
									echo $(psuc Done)
									let "c++"
								else
									echo $(perr "Error. Check logs @ '$LOGFD'")
									# skip to next resolution
									break
								fi
							fi
						done
						# if ok at first resolution exit for cicle
						if [[ $desk_state -eq 1 ]]
						then
							break
						else
							echo $(pwarn "[!] If you have still error, after end of script try reboot device.")
						fi
					done
				# case display :1
				elif [[ $vncType2 -eq 2 ]]
				then
					for vr in "1024x768" "1920x1080"
					do
						echo -n "[*] kill vnc... "
						if sudo -u $user vncserver -kill :1 &>>$LOGFD
						then
							echo $(psuc Done)
						else
							echo $(perr "Error. Check logs @ '$LOGFD'")
						fi
						echo -n "[*] change vnc resolution to $vr... "
						if raspi-config nonint do_vnc_resolution $vr &>>$LOGFD
						then
							echo $(psuc Done)
						else
							echo $(perr "Error. Check logs @ '$LOGFD'")
						fi
						# case bind iface
						if [[ $vnclif -eq 1 ]]
						then
							echo -n "[*] re-start vncserver @ $iface:5901... "
							# IpClientAddresses is a workaround of a not working IpListenAddresses
							if sudo -u $user vncserver IpListenAddresses=${apSub%.*}.1 IpClientAddresses=+${apSub%.*}.1/24 -nolisten tcp &>>$LOGFD
							then
								echo $(psuc "Done!")
							else
								echo $(perr "Error. Check logs @ '$LOGFD'")
							fi
						else
							echo -n "[*] re-start vncserver @ port 5901... "
							if sudo -u $user vncserver -nolisten tcp &>>$LOGFD
							then
								echo $(psuc "Done!")
							else
								echo $(perr "Error. Check logs @ '$LOGFD'")
							fi
						fi
						echo ""
						c=0
						while :
						do
							read -p "Try reconnect. OK now? (y/n) "
							if [[ $REPLY =~ ^(y|Y) ]]
							then
								desk_state=1
								break
							elif [[ $REPLY =~ ^(n|N) ]]
							then
								if [[ $c -gt 0 ]]
								then
									# skip to next resolution
									break
								fi
								echo -n "[*] change xrandr resolution to $vr... "
								if xrandr -d :0 --fb $vr &>>$LOGFD
								then
									echo $(psuc Done)
									let "c++"
								else
									echo $(perr "Error. Check logs @ '$LOGFD'")
									# skip to next resolution
									break
								fi
							fi
						done
						# if ok at first resolution exit for cicle
						if [[ $desk_state -eq 1 ]]
						then
							break
						else
							echo $(pwarn "[!] If you have still error, after end of script try reboot device.")
						fi
					done
				fi
			# case tightvncserver
			elif [[ "$vncType" == "tight" ]]
			then
				echo -n "[*] kill vnc... "
				if sudo -u $user vncserver -kill :1 &>>$LOGFD
				then
					echo $(psuc Done)
				else
					echo $(perr "Error. Check logs @ '$LOGFD'")
				fi
				echo -n "[*] check DE... "
				if [[ "$XDG_CURRENT_DESKTOP" ]]
				then
					echo $(psuc "found $XDG_CURRENT_DESKTOP")
				else
					echo $(perr "not found. When script end you need to modify config file manually.")
				fi
				echo -n "[*] change xstartup config... "
				if [[ -f "/home/$user/.vnc/xstartup" ]]
				then
					cp /home/$user/.vnc/xstartup /home/$user/.vnc/xstartup.preAVM
				fi
				if [[ "$XDG_CURRENT_DESKTOP" == "LXDE" ]]
				then
					sudo -u $user echo -e "#!/bin/bash\n\n"\
"xrdb $HOME/.Xresources\n"\
"xsetroot -solid grey\n"\
"export XKL_XMODMAP_DISABLE=1\n"\
"/usr/bin/startlxde" > /home/$user/.vnc/xstartup
					echo $(psuc "Done")
				elif [[ "$XDG_CURRENT_DESKTOP" == "XFCE" ]]
				then
					sudo -u $user echo -e "#!/bin/bash\n\n"\
"xsetroot -solid grey\n"\
"unset SESSION_MANAGER\n"\
"unset DBUS_SESSION_BUS_ADDRESS\n"\
"startxfce4 &" > /home/$user/.vnc/xstartup
					echo $(psuc "Done")
				else
					echo $(perr "DesktopEnvironment not implemented. Leave default configuration.")
				fi
				
				# restart vnc checking iface
				if [[ $vnclif -eq 1 ]]
				then
					echo -n "[*] re-start vncserver @ $iface:5901... "
					if sudo -u $user vncserver -interface ${apSub%.*}.1 -nolisten tcp &>>$LOGFD
					then
						echo $(psuc "Done!")
					else
						echo $(perr "Error. Check logs @ '$LOGFD'")
					fi
				else
					echo -n "[*] re-start vncserver @ port 5901... "
					if sudo -u $user vncserver -nolisten tcp &>>$LOGFD
					then
						echo $(psuc "Done!")
					else
						echo $(perr "Error. Check logs @ '$LOGFD'")
					fi
				fi
			fi
			# exit main cicle
			break
		fi
	done
	echo ""
	# enable/disable vnc on boot
	echo "Do you want enable vncserver on boot? (y/n)"
	while :
	do
		read -p "> "
		if [[ $REPLY =~ ^(y|Y) ]]
		then
			echo -e "\n--- enable vncserver on boot ---\n" >>$LOGFD
			echo -n "[*] enable vncserver on boot... "
			# case realvncserver
			if [[ "$vncType" == "real" ]]
			then
				# case display physical :0
				if [[ "$vncType2" -eq 1 ]]
				then
					if systemctl enable vncserver-x11-serviced &>>$LOGFD
					then
						echo $(psuc "Done!")
					else
						echo $(perr "Error. Check logs @ '$LOGFD'")
					fi
				# case display virtual :1
				elif [[ "$vncType2" -eq 2 ]]
				then
					echo -ne "\n\tcreate startup script @ '/home/$user/.vnc/VncConf.sh' ... "
					# case specific iface
					if [[ $vnclif -eq 1 ]]
					then
						sudo -u $user echo -e "#!/bin/bash\n\nvncserver IpListenAddresses=${apSub%.*}.1 IpClientAddresses=+${apSub%.*}.1/24 -nolisten tcp" > /home/$user/.vnc/VncConf.sh
					else
						sudo -u $user echo -e "#!/bin/bash\n\nvncserver -nolisten tcp" > /home/$user/.vnc/VncConf.sh
					fi
					echo echo $(psuc "Done!")
					echo -ne "\tadd execution permissions... "
					sudo -u $user chmod u+x /home/$user/.vnc/VncConf.sh
					echo $(psuc "Done!")
					echo -ne "\tcreate autostart desktop entry @ '/home/$user/.config/autostart/VncServerVirtual.desktop' ... "
					if ! [[ -d "/home/$user/.config/autostart" ]]
					then
						sudo -u $user mkdir /home/$user/.config/autostart
					fi
					sudo -u $user echo -e "[Desktop Entry]\n"\
"Type=Application\n"\
"Name=VncServerVirtual\n"\
"Exec=/home/$user/.vnc/VncConf.sh\n"\
"StartupNotify=False" > /home/$user/.config/autostart/VncServerVirtual.desktop
					echo $(psuc "Done")
				fi
			# case tightvncserver
			elif [[ "$vncType" == "tight" ]]
			then
				echo -ne "\n\tcreate startup script @ '/home/$user/.vnc/VncConf.sh' ... "
				# case specific iface
				if [[ $vnclif -eq 1 ]]
				then
					sudo -u $user echo -e "#!/bin/bash\n\nvncserver -interface ${apSub%.*}.1 -nolisten tcp" > /home/$user/.vnc/VncConf.sh
				else
					sudo -u $user echo -e "#!/bin/bash\n\nvncserver -nolisten tcp" > /home/$user/.vnc/VncConf.sh
				fi
				echo echo $(psuc "Done!")
				echo -ne "\tadd execution permissions... "
				sudo -u $user chmod u+x /home/$user/.vnc/VncConf.sh
				echo $(psuc "Done!")
				echo -ne "\tcreate autostart desktop entry @ '/home/$user/.config/autostart/VncServerVirtual.desktop' ... "
				if ! [[ -d "/home/$user/.config/autostart" ]]
				then
					sudo -u $user mkdir /home/$user/.config/autostart
				fi
				sudo -u $user echo -e "[Desktop Entry]\n"\
"Type=Application\n"\
"Name=VncServerVirtual\n"\
"Exec=/home/$user/.vnc/VncConf.sh\n"\
"StartupNotify=False" > /home/$user/.config/autostart/VncServerVirtual.desktop
				echo $(psuc "Done")
			fi
			vncBoot=1
			break
		elif [[ $REPLY =~ ^(n|N) ]]
		then
			vncBoot=0
			break
		fi
	done
}

# restore 
function restoreAll(){
	user=$(users |awk '{print $1}')
	echo -e "\n--- restore all ---\n" > $LOGFD
	# stop services
	echo -n "[*] kill hostapd service... "
	if systemctl stop hostapd &>>$LOGFD
	then
		echo $(psuc "Done")
	else
		echo $(perr "Error. Check logs @ '$LOGFD'")
	fi
	echo -n "[*] kill dnsmasq service... "
	if systemctl stop dnsmasq &>>$LOGFD
	then
		echo $(psuc "Done")
	else
		echo $(perr "Error. Check logs @ '$LOGFD'")
	fi
	echo "[*] kill vncserver..."
	# check if vnc run as service or instance
	if systemctl is-active vncserver-x11-serviced &>>$LOGFD
	then
		echo -ne "\t...stop service... "
		if systemctl stop vncserver-x11-serviced &>>$LOGFD
		then
			echo $(psuc "Done")
		else
			echo $(perr "Error. Check logs @ '$LOGFD'")
		fi
	else
		res=$(find /home/$user/.vnc/ -type f -name "*.pid" | sed "s/.*\([^:]\).pid/\1/")
		if [[ $res ]]
		then
			for i in ${res[@]}
			do
				echo -ne "\t...stop istance :$i ... "
				if sudo -u $user vncserver -kill :$i &>>$LOGFD
				then
					echo $(psuc "Done")
				else
					echo $(perr "Error. Check logs @ '$LOGFD'")
				fi
			done
		else
			echo $(psuc "...no service/instance running...")
		fi
	fi		
	
	# restore wlan behavior
	echo -n "[*] restore dhcp and interfaces behavior @ '/etc/dhcpcd.conf'... "
	if [[ -f "/etc/dhcpcd.conf.preAVM" ]]
	then
		if mv /etc/dhcpcd.conf.preAVM /etc/dhcpcd.conf &>>$LOGFD
		then
			echo $(psuc "Done")
		else
			echo $(perr "Error. Check logs @ '$LOGFD'")
		fi
	else
		echo $(pwarn "'/etc/dhcpcd.conf.preAVM' not found. Check manually if '/etc/dhcpcd.conf' is already original file or edited file.")
	fi
	# restart dhcp service
	echo -n "[*] restart dhcp service... "
	if systemctl restart dhcpcd &>>$LOGFD
	then
		echo $(psuc "Done")
	else
		echo $(perr "Error. Check logs @ '$LOGFD'")
	fi
	
	echo ""
	echo $(psuc "=> Now normal wifi behavior should be restored.")
	echo ""
	
	# check AP services to disable on boot 
	declare -a unPkg
	echo -e "\n--- check enabled packages ---\n" >>$LOGFD
	
	if systemctl is-enabled hostapd &>>$LOGFD
	then
		unPkg+=("hostapd")
	fi
	if systemctl is-enabled dnsmasq &>>$LOGFD
	then
		unPkg+=("dnsmasq")
	fi
	if [[ ${#unPkg[@]} -ne 0 ]]
	then
		echo "[*] Found start-on-boot AP packages. Do you want disable them? (y/n)"
		while :
		do
			read -p "> "
			if [[ $REPLY =~ ^(y|Y) ]]
			then
				for i in ${unPkg[@]}
				do
					echo -e "\n--- disable package $i ---\n" >>$LOGFD 
					echo -n "[*] disable $i... "
					if systemctl disable $i &>>$LOGFD
					then
						echo $(psuc "Done")
					else
						echo $(perr "Error. Check logs @ '$LOGFD'")
					fi
				done
				break
			elif [[ $REPLY =~ ^(n|N) ]]
			then
				break
			fi
		done
	fi
	
	# check AP packages for uninstall
	unPkg=()
	for p in hostapd dnsmasq
	do
		echo -e "\n--- uninstall ops: check installed $p pkg ---\n" >>$LOGFD
		dpkg-query -W -f='${Status}' $p 2>>$LOGFD | grep -iw 'install' &>>$LOGFD
		if [[ $? -eq 0 ]]
		then
			unPkg+=("$p")
		fi
	done

	if [[ ${#unPkg[@]} -ne 0 ]]
	then
		echo "[*] Found AP packages. Do you want uninstall them? (y/n)"
		while :
		do
			read -p "> "
			if [[ $REPLY =~ ^(y|Y) ]]
			then
				for i in ${unPkg[@]}
				do
					echo -e "\n--- uninstall packages $i ---\n" >>$LOGFD
					echo -n "[*] uninstall $i... "
					if apt-get -y --purge remove $i &>>$LOGFD
					then
						echo $(psuc "Done")
					else
						echo $(perr "Error. Check logs @ '$LOGFD'")
					fi
					if [[ "$i" == "hostapd" ]] && [[ -d /etc/hostapd ]]
					then
						echo -e "\n--- remove /etc/hostapd folder ---\n" >>$LOGFD
						echo -n "[*] remove residual files... "
						if rm -r /etc/hostapd &>>$LOGFD
						then
							echo $(psuc "Done")
						else
							echo $(perr "Error. Check logs @ '$LOGFD'")
						fi
					fi
					if [[ "$i" == "dnsmasq" ]] && [[ -f /etc/dnsmasq.conf.preAVM ]]
					then
						echo -e "\n--- remove /etc/dnsmasq.conf.preAVM folder ---\n" >>$LOGFD
						echo -n "[*] remove residual files... "
						if rm /etc/dnsmasq.conf.preAVM &>>$LOGFD
						then
							echo $(psuc "Done")
						else
							echo $(perr "Error. Check logs @ '$LOGFD'")
						fi
					fi
				done
				break
			elif [[ $REPLY =~ ^(n|N) ]]
			then
				break
			fi
		done
	fi
	
	# REALVNC server
	echo -e "\n--- uninstall osp: check realvnc server package ---\n" >>$LOGFD
	if dpkg-query -W -f='${Status}' realvnc-vnc-server 2>>$LOGFD | grep -iw 'install' &>>$LOGFD
	then
		echo "[*] found REALVNC server package installed"
		# disable on boot
		echo -e "\n--- check vncserver-x11-serviced enabled ---\n" >>$LOGFD
		if systemctl is-enabled vncserver-x11-serviced &>>$LOGFD
		then
			# case use physical display
			echo "[*] VNC server is enabled on boot. Do you want disable it? (y/n)"
			while :
			do
				read -p "> "
				if [[ $REPLY =~ ^(y|Y) ]]
				then
					echo -e "\n--- disable vnc service on boot ---\n" >>$LOGFD 
					echo -n "[*] disable vncserver-x11-serviced... "
					if systemctl disable vncserver-x11-serviced &>>$LOGFD
					then
						echo $(psuc "Done")
					else
						echo $(perr "Error. Check logs @ '$LOGFD'")
					fi
					break
				elif [[ $REPLY =~ ^(n|N) ]]
				then
					break
				fi
			done
		else
			# case use virtual display
			if [[ -f "/home/$user/.config/autostart/VncServerVirtual.desktop" ]]
			then
				echo "[*] VNC server is enabled on boot. Do you want disable it? (y/n)"
				while :
				do
					read -p "> "
					if [[ $REPLY =~ ^(y|Y) ]]
					then
						echo -e "\n--- remove vnc autostart on boot entry @ '/home/$user/.config/autostart/VncServerVirtual.desktop' ---\n" >>$LOGFD 
						echo -n "[*] remove autostart desktop entry... "
						if rm /home/$user/.config/autostart/VncServerVirtual.desktop &>>$LOGFD
						then
							echo $(psuc "Done")
						else
							echo $(perr "Error. Check logs @ '$LOGFD'")
						fi
						break
					elif [[ $REPLY =~ ^(n|N) ]]
					then
						break
					fi
				done
			fi
		fi
		
		# uninstall
		echo "[*] Do you want uninstall it? (y/n)"
		while :
		do
			read -p "> "
			if [[ $REPLY =~ ^(y|Y) ]]
			then
				echo -e "\n--- uninstall realvnc-vnc-server ---\n" >>$LOGFD 
				echo -n "[*] uninstall realvnc-vnc-server... "
				if apt-get -y --purge remove realvnc-vnc-server &>>$LOGFD
				then
					echo $(psuc "Done")
				else
					echo $(perr "Error. Check logs @ '$LOGFD'")
				fi
				if [[ -f "/home/$user/.vnc/VncConf.sh" ]]
				then
					echo -e "\n--- remove vnc conf file @ '/home/$user/.vnc/VncConf.sh' ---\n" >>$LOGFD 
					echo -n "[*] remove vnc config file... "
					if rm /home/$user/.vnc/VncConf.sh &>>$LOGFD
					then
						echo $(psuc "Done")
					else
						echo $(perr "Error. Check logs @ '$LOGFD'")
					fi
				fi
				break
			elif [[ $REPLY =~ ^(n|N) ]]
			then
				break
			fi
		done
	fi

	# tightvncserver
	echo -e "\n--- uninstall ops: check tightvncserver server package ---\n" >>$LOGFD
	if dpkg-query -W -f='${Status}' tightvncserver 2>>$LOGFD | grep -iw 'install' &>>$LOGFD
	then
		echo "[*] found tightvncserver package installed"
		# check start on boot
		if [[ -f "/home/$user/.config/autostart/VncServerVirtual.desktop" ]]
		then
			echo "[*] tightvncserver is enabled on boot. Do you want disable it? (y/n)"
			while :
			do
				read -p "> "
				if [[ $REPLY =~ ^(y|Y) ]]
				then
					echo -e "\n--- remove vnc autostart on boot entry @ '/home/$user/.config/autostart/VncServerVirtual.desktop' ---\n" >>$LOGFD 
					echo -n "[*] remove autostart desktop entry... "
					if rm /home/$user/.config/autostart/VncServerVirtual.desktop &>>$LOGFD
					then
						echo $(psuc "Done")
					else
						echo $(perr "Error. Check logs @ '$LOGFD'")
					fi
					break
				elif [[ $REPLY =~ ^(n|N) ]]
				then
					break
				fi
			done
		fi
		# uninstall
		echo "[*] Do you want uninstall it? (y/n)"
		while :
		do
			read -p "> "
			if [[ $REPLY =~ ^(y|Y) ]]
			then
				echo -e "\n--- uninstall tightvncserver ---\n" >>$LOGFD 
				echo -n "[*] uninstall tightvncserver... "
				if apt-get -y --purge remove tightvncserver &>>$LOGFD
				then
					echo $(psuc "Done")
				else
					echo $(perr "Error. Check logs @ '$LOGFD'")
				fi
				if [[ -f "/home/$user/.vnc/VncConf.sh" ]]
				then
					echo -e "\n--- remove vnc conf file @ '/home/$user/.vnc/VncConf.sh' ---\n" >>$LOGFD 
					echo -n "[*] remove vnc config file... "
					if rm /home/$user/.vnc/VncConf.sh &>>$LOGFD
					then
						echo $(psuc "Done")
					else
						echo $(perr "Error. Check logs @ '$LOGFD'")
					fi
				fi
				break
			elif [[ $REPLY =~ ^(n|N) ]]
			then
				break
			fi
		done
	fi
	
	echo ""
	echo $(psuc "CLEAN! Now reboot to make sure everything is alright")
	echo ""
}

# main
# banner
echo "    _       __     __          __  __           _      "
echo "   / \   _ _\ \   / / __   ___|  \/  | ___   __| | ___ "
echo "  / _ \ | '_ \ \ / / '_ \ / __| |\/| |/ _ \ / _\` |/ _ \\"
echo " / ___ \| |_) \ V /| | | | (__| |  | | (_) | (_| |  __/"
echo "/_/   \_\ .__/ \_/ |_| |_|\___|_|  |_|\___/ \__,_|\___|"
echo "        |_|                                            "
echo ""
echo $(pwarn "DISCLAIMER: use this script at your own risk !")

if [[ $(id -u) -ne 0 ]]
then
	echo $(perr "This script must be run as root.")
	echo ""
	exit 0
fi

# menu
echo "Select mode:"
echo "1) AP                 // setup only an Access Point on the defined interface."
echo "                         pkgs installed: hostapd + dnsmasq"
echo "2) AP + VNC           // setup an Access Point and Vnc server on the defined interface."
echo "                         pkgs installed: hostapd + dnsmasq + vncserver(multiple choices)"
echo "3) RestoreAll         // restore device wifi behavior as before install AP. More options available."
echo "4) help               // show info about tool."
echo "5) list customFile    // show a list of files you can edit manually for troubleshooting or add features." 
echo "0) Quit."
while :
do
	echo ""
	read -p "> "
	case $REPLY in
		1)
			checkRequirements
			setupAp
			break
			;;
		2)
			checkRequirements APVNC
			setupAp
			setupVnc
			WANTVNC=1
			break
			;;
		3)
			restoreAll
			exit 0
			;;
		4)
			echo ""
			tput setaf 3
			echo "The purpose of this script is to quick setup and configure"
			echo "an AP or an AP + VNCServer to connect to this device."
			echo "No traffic forward rules will be made."
			echo -e "\e[3mSpecially designed for RPI\e[0m"
			tput setaf 3
			echo "Example:"
			echo "1 => AP =>         pc/phone -> ssh -> rpi (AP on wlanX)"
			echo "2 => AP+VNC =>     pc/phone -> VncViewer -> rpi (AP on wlanX)"
			tput sgr0
			echo ""
			echo "Select Mode:"
			;;
		5)
			user=$(users | awk '{print $1}')
			list_fconf=("/etc/dhcpcd.conf" "/etc/dnsmasq.conf" "/etc/hostapd/hostapd.conf" "/home/$user/.vnc/xstartup" "/home/$user/.vnc/VncConf.sh" "/home/$user/.config/autostart/VncServerVirtual.desktop")
			for f in ${list_fconf[@]}
			do
				echo "* $f"
			done
			echo ""
			echo "Select Mode:"
			;;
		0)
			echo ""
			echo $(psuc "You say EXIT.")
			echo ""
			exit 0
			;;
		*)
			echo -e $(pwarn "\e[3mchoice must be a number within menu\e[0m")
			;;
	esac
done

echo ""
echo $(psuc "[+] ALL DONE!")
echo ""
echo "=> AP ssid: $(psuc $apName)"
echo "=> AP passwd: $(psuc $apPwd)"
echo "=> AP iface: $(psuc $iface)"
echo "=> AP ip: $(psuc ${apSub%.*}.1)"
echo "=> AP range: $(psuc ${apSub%.*}.$apRangeStart - ${apSub%.*}.$apRangeEnd)"
if [[ $WANTVNC -eq 1 ]] ; then
	if [[ "$vncType" == "real" && $vncType2 -eq 1 ]] ; then
		echo "=> VNC type: physical"
		echo "=> VNC port: 5900"
		echo "=> VNC display :0"
	else
		echo "=> VNC type: virtual"
		echo "=> VNC port: 5901"
		echo "=> VNC display :1"
	fi
fi
echo ""
if [[ $apBoot -eq 0 ]]
then
	echo $(pwarn "Remember: you have chosen standalone AP.")
	echo $(pwarn "If you shutdown/reboot device you need to start manually 'hostapd' and 'dnsmasq' services.")
fi
if [[ $WANTVNC -eq 1 ]] ; then
	if [[ $vncBoot -eq 0 ]]
	then
		echo $(pwarn "Remember: you have chosen standalone VNCserver.")
		echo $(pwarn "If you shutdown/reboot device you need to start manually vncserver.")
	fi
fi
if [[ $apBoot -eq 1 ]] && [[ $vncBoot -eq 1 ]]
then
	echo ""
	echo $(psuc "Please now REBOOT to make sure everything is alright!")
fi
echo ""
exit 0