echo "DNS=10.1.1.1" >> /etc/systemd/resolved.conf
echo "Domains=lan"  >> /etc/systemd/resolved.conf
echo "Cache=no" >> /etc/systemd/resolved.conf
echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
systemctl restart systemd-resolved
