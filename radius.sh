#!/bin/bash
set -e


echo "=== Update & Upgrade ระบบ ==="
apt update -y && apt upgrade -y

echo "=== ติดตั้ง Service ที่ต้องใช้ ==="
apt install -y net-tools vim apache2 php mariadb-server mariadb-client freeradius-mysql freeradius

echo "=== เริ่มต้น MariaDB ==="
systemctl enable --now mariadb

echo "=== สร้าง Database และ User สำหรับ FreeRADIUS ==="
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS radius_db;
CREATE USER IF NOT EXISTS 'radius_user'@'localhost' IDENTIFIED BY 'radius_pass123';
GRANT ALL PRIVILEGES ON radius_db.* TO 'radius_user'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "=== Import Schema FreeRADIUS ==="
mysql -u radius_user -p radius_pass123 radius_db < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql

ln -sf /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/sql

echo "=== แก้ไขไฟล์ mods-available/sql ==="
# ใช้ sed แก้ค่า server, port, login, password, radius_db และเอา comment ออก
sed -i 's|^\s*server\s*=.*|server = "localhost"|' /etc/freeradius/3.0/mods-available/sql
sed -i 's|^\s*port\s*=.*|port = 3306|' /etc/freeradius/3.0/mods-available/sql
sed -i 's|^\s*login\s*=.*|login = "radius_user"|' /etc/freeradius/3.0/mods-available/sql
sed -i 's|^\s*password\s*=.*|password = "radius_pass123"|' /etc/freeradius/3.0/mods-available/sql
sed -i 's|^\s*radius_db\s*=.*|radius_db = "radius_db"|' /etc/freeradius/3.0/mods-available/sql

echo "=== Comment บล็อก TLS/SSL ของ MySQL ใน mods-available/sql ==="
# comment บล็อก tls { … } ระหว่างบรรทัด 86-96
sed -i '86,96 s/^/#/' /etc/freeradius/3.0/mods-available/sql

echo "=== เพิ่ม client ใน clients.conf โดยไม่เขียนทับเดิม ==="
# ตรวจสอบก่อนว่ามี client all อยู่หรือยัง
grep -q 'client all' /etc/freeradius/3.0/clients.conf || cat >> /etc/freeradius/3.0/clients.conf <<EOF

client all {
    ipaddr = 0.0.0.0/0
    secret = 12345
    nastype = other
}
EOF

#echo "=== Enable SQL Module ใน sites-enabled/default ==="
#for section in authorize accounting session post-auth; do
    # ถ้าเป็น '# sql' เอา # ออก
#    sed -i "/^$section {/,/^}/{s/^#[[:space:]]*sql/sql/}" /etc/freeradius/3.0/sites-enabled/default
    # ถ้าเป็น '-sql' เอา - ออก
#    sed -i "/^$section {/,/^}/{s/^-sql/sql/}" /etc/freeradius/3.0/sites-enabled/default
#done

echo "=== สร้าง User got และกำหนดสิทธิ Bandwidth ==="
mysql -u radius_user -pradius_pass123 radius_db <<EOF
INSERT INTO radcheck (username, attribute, op, value) VALUES ('bncc', 'Cleartext-Password', ':=', '12345');
INSERT INTO radusergroup (username, groupname, priority) VALUES ('bncc', 'admin', 1);
INSERT INTO radgroupcheck (groupname, attribute, op, value) VALUES ('admin', 'Simultaneous-Use', ':=', '3');
INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES ('admin', 'Mikrotik-Rate-Limit', ':=', '100M/100M');
INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES ('admin', 'WISPr-Bandwidth-Max-Down', ':=', '100000000');
INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES ('admin', 'WISPr-Bandwidth-Max-Up', ':=', '100000000');
INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES ('admin', 'Idle-Timeout', ':=', '900');
INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES ('admin', 'Session-Timeout', ':=', '14400');
EOF


echo "=== ตั้งค่าสิทธิ์ไฟล์และโฟลเดอร์ ==="
chown -R freerad:freerad /etc/freeradius/3.0
chmod -R 640 /etc/freeradius/3.0/*
find /etc/freeradius/3.0 -type d -exec chmod 750 {} \;

chown -R mysql:mysql /var/lib/mysql
chmod 750 /var/lib/mysql

echo "=== Restart Services ==="
systemctl enable --now freeradius
systemctl restart freeradius
systemctl enable --now apache2

apt install phpmyadmin php-mysql -y
systemctl restart apache2

echo "=== อนุญาต Firewall port ที่จำเป็น ==="
ufw allow 1812/udp
ufw allow 1813/udp
ufw allow 80/tcp
ufw allow 3306/tcp
ufw allow 22/tcp
ufw reload

echo "=== เสร็จสิ้น! FreeRADIUS พร้อมใช้งานผ่าน DB แล้ว ==="
