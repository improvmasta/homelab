#!/bin/bash

##
#SET YOUR SMB SHARES HERE - "//server/share /media/localshare"
##
SERVER="10.1.1.3"
SHARE1="d"
SHARE2="e"
SHARE3="f"

##QUIT IF NOT ROOT
if [ "$(id -u)" -ne 0 ]; then
        echo 'This script must be run by root' >&2
        exit 1
fi

##
#Collect local network SMB client user/pw
##
read -p "Enter current username: " CUSER
read -p "Enter LAN Samba username: " SMBUSER
read -s -p "Enter LAN Samba password: " SMBPW

##
#Install Basic Software
##
apt-get update -y
apt-get upgrade -y
apt install -y net-tools gcc make perl samba cifs-utils winbind curl git bzip2 tar
apt-get autoremove
apt-get autoclean
journalctl --vacuum-time=3d

##
#Share / with Samba - script will prompt for password
##
echo "[${CUSER}]" >>  /etc/samba/smb.conf
echo "    path = /home/${CUSER}" >>  /etc/samba/smb.conf
echo "    read only = no" >>  /etc/samba/smb.conf
echo "    browsable = yes" >>  /etc/samba/smb.conf
service smbd restart
ufw allow samba
smbpasswd -a ${CUSER}

##
#Connect to Server Drives with smbclient
##
mkdir /media/${SHARE1} ;mkdir /media/${SHARE2};mkdir /media/${SHARE3}
echo "//${SERVER}/${SHARE1} /media/${SHARE1} cifs nobrl,username=${SMBUSER},password=${SMBPW},iocharset=utf8,file_mode=0777,dir_mode=0777 0 0" >> /etc/fstab
echo "//${SERVER}/${SHARE2} /media/${SHARE2} cifs nobrl,username=${SMBUSER},password=${SMBPW},iocharset=utf8,file_mode=0777,dir_mode=0777 0 0" >> /etc/fstab
echo "//${SERVER}/${SHARE3} /media/${SHARE3} cifs nobrl,username=${SMBUSER},password=${SMBPW},iocharset=utf8,file_mode=0777,dir_mode=0777 0 0" >> /etc/fstab
mount -a

##
#Setup Aliases
##
echo "alias dock='cd ~/.docker/compose'" >> /home/${CUSER}/.bashrc
echo "alias dc='cd ~/.config/appdata/'" >> /home/${CUSER}/.bashrc
echo "alias dr='docker compose -f ~/.docker/compose/docker-compose.yml restart $1'" >> /home/${CUSER}/.bashrc
echo "alias dstart='docker compose -f ~/.docker/compose/docker-compose.yml start $1'" >> /home/${CUSER}/.bashrc
echo "alias dstop='docker compose -f ~/.docker/compose/docker-compose.yml stop $1'" >> /home/${CUSER}/.bashrc
echo "alias lsl='ls -la'" >> /home/${CUSER}/.bashrc
source .bashrc

##
#Create Update script
##
echo "sudo apt-get update -y;sudo apt-get upgrade -y;sudo apt-get autoremove;sudo apt-get autoclean;sudo journalctl --vacuum-time=3d;cd ~/.config/appdata/plex/Library/'Application Support'/'Plex Media Server'/Logs;ls | grep -v '\.log$' | xargs rm" > /home/${CUSER}/update
chmod +x /home/${CUSER}/update

##
#Create DockSTARTer Install Script
##
echo 'git clone https://github.com/GhostWriters/DockSTARTer "/home/${USER}/.docker"' > installds
echo 'bash /home/"${USER}"/.docker/main.sh -vi' >> installds
chmod +x /home/${CUSER}/installds
echo "****YOU MUST RUN ./installds TO INSTALL DOCKSTARTER***"
