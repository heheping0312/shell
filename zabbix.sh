#!/bin/bash

yum_base="/etc/yum.repos.d"
nginx_config="/usr/local/nginx/conf/nginx.conf"
zabbixserver_conf="/usr/local/etc/zabbix_server.conf"
zabbixclient_conf="/usr/local/etc/zabbix_agentd.conf"
soft_pwd=$PWD

#yum源配置函数
yum_config(){
    read -p "YUM仓库不可用,请输入新的YUM源:" yum_src
    [ ! -d $yum_base/repo ]&&mkdir $yum_base/repo
    repo_count=`ls $yum_base/*.repo | wc -l `
    [ $repo_count -gt 0 ]&&mv $yum_base/*.repo $yum_base/repo
    yum-config-manager --add $yum_src  &>/dev/null
    reponame=`echo $yum_src | awk -F/ '{print $3,$4}' | sed 's/ /_/'`
    echo "gpgcheck=0" >> $yum_base/${reponame}.repo 
}

#修改配置文件函数
sed_config(){
    fst="`echo $1 | awk -F ' |=' '{print $1}'`"
    len=`awk -F ' |=' -v x=$fst '{if($1==x){print NR}}' $2`
    [ ! -z $len ]&& sed -i "$len c $1" $2 || sed -i "${3}i $1" $2
}


#修改zabbix_server.conf配置文件
sed_serverzab(){
   sed_config "DBHost=localhost" $zabbixserver_conf 65
   sed_config "DBName=zabbix" $zabbixserver_conf 65
   sed_config "DBUser=zabbix" $zabbixserver_conf 65
   sed_config "DBPassword=zabbix" $zabbixserver_conf 65
   sed_config "LogFile=/tmp/zabbix_server.log" $zabbixserver_conf 65
}

#修改 zabbix_agent.conf (被动)配置文件
sed_clientzab(){
   sed_config "Server=127.0.0.1,$2" $zabbixclient_conf 65
   sed_config "ServerActive=127.0.0.1,$2" $zabbixclient_conf 65
   sed_config "Hostname=$1" $zabbixclient_conf 65
   sed_config "LogFile=/tmp/zabbix_server.log" $zabbixclient_conf 65
   sed_config "UnsafeUserParameters=1" $zabbixclient_conf 65
   sed_config "Include=/usr/local/etc/zabbix_agentd.conf.d/" $zabbixclient_conf 65
}

#修改 zabbix_agent.conf (主动)配置文件
sed_clientzabl(){
   sed -i "/^Server=127.0.0.1/s/^/#/" $zabbixclient_conf 
   sed_config "StartAgents=0" $zabbixclient_conf 
   sed_config "ServerActive=$2" $zabbixclient_conf 
   sed_config "Hostname=$1" $zabbixclient_conf 
   sed_config "RefreshActiveChecks=120" $zabbixclient_conf 
   sed_config "UnsafeUserParameters=1" $zabbixclient_conf 
   sed_config "Include=/usr/local/etc/zabbix_agentd.conf.d/" $zabbixclient_conf
   
}

#配置mysql数据库
mysql_expect(){
expect <<EOF
spawn   mysql
expect "> " {send "create database zabbix character set utf8;\r"}
expect ">" {send "grant all on zabbix.* to zabbix@'localhost' identified by 'zabbix';\r"}
expect ">" {send "exit\r"} 
expect ">" {send "exit\r"}
EOF
}

yum_install(){
    x=true
    while $x
    do
        yum -y install $1 &>/dev/null
        if [ $? -ne 0 ];then
           yum_config  
  	else
           x=false
        fi
    done
}

#快速搭键配置zabbix服务端
zabbix_servers(){ 
       yum_install "gcc pcre-devel openssl-devel" 
       cd $soft_pwd/lnmp_soft
       tar -xf nginx-1.12.2.tar.gz && cd ./nginx-1.12.2 
       id nginx &>/dev/null
       [ $? -ne 0 ]&&useradd -s /sbin/nologin nginx
       ./configure --prefix=/usr/local/nginx --user=nginx --group=nginx --with-http_ssl_module   &>/dev/null
       make &>/dev/null && make install &>/dev/null
       yum_install "php php-mysql mariadb mariadb-devel mariadb-server"
       cd $soft_pwd/lnmp_soft
       yum -y install php-fpm-5.4.16-42.el7.x86_64.rpm &>/dev/null
       sed_config "fastcgi_buffers 8 16k;" $nginx_config 65
       sed_config "fastcgi_buffer_size 32k;" $nginx_config 65
       sed_config "fastcgi_connect_timeout 300;" $nginx_config 65
       sed_config "fastcgi_send_timeout 300;" $nginx_config 65
       sed_config "fastcgi_read_timeout 300;" $nginx_config 65
       sed -i "/fastcgi_param  SCRIPT_FILENAME/d" $nginx_config
       sed -i "70,76 s/#//" $nginx_config
       sed -i "s/include        fastcgi_params;/include        fastcgi.conf;/" $nginx_config
       systemctl start mariadb.service
       systemctl start php-fpm.service
        ss -anultp | grep nginx &>/dev/null && killall nginx 
       /usr/local/nginx/sbin/nginx
       firewall-cmd --set-default-zone=trusted &>/dev/null
       setenforce 0
       cd $soft_pwd/lnmp_soft
       yum_install "net-snmp-devel curl-devel"
       yum -y install libevent-devel-2.0.21-4.el7.x86_64.rpm &>/dev/null
       tar -xf zabbix-3.4.4.tar.gz
       cd zabbix-3.4.4/
       ./configure --enable-server --enable-proxy --enable-agent --with-mysql=/usr/bin/mysql_config --with-net-snmp --with-libcurl  &>/dev/null
       make &>/dev/null && make install &>/dev/null
       yum_install "expect"
       mysql_expect &>/dev/null
       cd $soft_pwd/lnmp_soft/zabbix-3.4.4/database/mysql/
       mysql -uzabbix -pzabbix zabbix < schema.sql 
       mysql -uzabbix -pzabbix zabbix < images.sql 
       mysql -uzabbix -pzabbix zabbix < data.sql 
       cp -r $soft_pwd/lnmp_soft/zabbix-3.4.4/frontends/php/* /usr/local/nginx/html
       cp $soft_pwd/lnmp_soft/zabbix.conf.php /usr/local/nginx/html/conf
       chown  -R nginx:nginx /usr/local/nginx/html/
       sed_serverzab
       useradd -s /sbin/nologin zabbix &>/dev/null
       netstat -anutpl | grep ":10051" &>/dev/null
       [ $? -eq 0 ]&&killall zabbix_server
       zabbix_server
       read -p "请输入主机名" Hostname
       read -p "请输入zabbix服务器的ip地址:" servip
       sed_clientzab $Hostname $servip 
       netstat -anultp | grep ":10050" &>/dev/null
       [ $? -eq 0 ]&&killall zabbix_agentd
       zabbix_agentd
       cd $soft_pwd/lnmp_soft
       yum_install "php-gd php-xml"
       yum -y install php-bcmath-5.4.16-42.el7.x86_64.rpm &>/dev/null
       yum -y install php-mbstring-5.4.16-42.el7.x86_64.rpm &>/dev/null
       sed_config "date.timezone = Asia/Shanghai" /etc/php.ini 65
       sed_config "max_execution_time = 300" /etc/php.ini 65
       sed_config "post_max_size = 32M" /etc/php.ini 65
       sed_config "max_input_time = 300 " /etc/php.ini 65
       sed_config "memory_limit = 128M" /etc/php.ini 65
       systemctl restart php-fpm
}

#客户端安装源码安装zabbix
zabbix_install_client(){
    yum_install "gcc pcre-devel"
       useradd -s /sbin/nologin zabbix &>/dev/null
       cd $soft_pwd/lnmp_soft && tar -xf zabbix-3.4.4.tar.gz
       cd zabbix-3.4.4/ && ./configure --enable-agent &>/dev/null 
       make &>/dev/null &&make install &>/dev/null
       #return 11
}

#快速搭建被动模式客户端
zabbix_client(){ 
       zabbix_install_client 
       #if [ $? -eq 11 ];then
       read -p "请输入主机名" Hostname
       read -p "请输入zabbix服务器的ip地址:" servip
       sed_clientzab $Hostname $servip
       sed_config "EnableRemoteCommands=1" $zabbixclient_conf 65
       netstat -anultp | grep ":10050" &>/dev/null
       [ $? -eq 0 ]&&killall zabbix_agentd
       zabbix_agentd
       #fi
}

#快速搭键主动模式客户端
zabbix_client_l(){
     zabbix_install_client 
     #if [ $? -eq 11 ];then
     read -p "请输入主机名" Hostname
     read -p "请输入zabbix服务器的ip地址:" servip
     sed_clientzabl $Hostname $servip
     netstat -anultp | grep ":10050" &>/dev/null
     [ $? -eq 0 ]&&killall zabbix_agentd
     zabbix_agentd
     #fi
}
    

#函数字典
declare -A CMDs
CMDs=(['s']="zabbix_servers" ['c']="zabbix_client" ['l']="zabbix_client_l")
tmp=('s' 'c' 'q' 'l')
#主函数
main_menu(){    #主程序菜单
    sed_config "retries=1" /etc/yum.conf  4
    tar -xf /root/lnmp_soft.tar.gz  
    clear
    echo  -e "***********               \033[32m 脚本菜单\033[m                  *************"
    echo "***********             zabbix_(S)erver              *************"    
    echo "***********             zabbix_(C)lient(被动模式)    *************"
    echo "***********             zabbix_(l)client(主动模式)   *************"
    echo "***********             (Q)uit                       *************"
    echo "***********             按键选择  S | C | l          *************"
    echo  -e "*********** \033[32m 注意安装的时候需要几分钟时间,请耐心等待\033[0m *************"
    while :
    do
        typeset -l choice
        read -p "请输入你的选择" choice
        [ -z $choice ]&&echo "没有输入,请重新输入!"&&continue
        uchoice=${choice::1}
        echo ${tmp[@]} | grep $uchoice &>/dev/null
        [ $? -ne 0 ]&&echo "选择不正确,请重新输入:"&&continue
        [ $uchoice == 'q' ]&&exit;
        echo  "正在部署,请稍等....."
        ${CMDs["$uchoice"]} 
        echo -e "\033[32m OK \033[0m"
    done
}
main_menu 
