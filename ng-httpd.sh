#!/bin/bash
CURDIR=$(cd $(dirname "$0"); pwd)
APCONFDIR=/etc/httpd/conf
NGCONFDIR=/usr/local/nginx/conf
DAROOTDIR=/usr/local/directadmin
DAUSERDIR=$DAROOTDIR/data/users
DATEMPDIR=$DAROOTDIR/data/templates
DAQUEUE=$DAROOTDIR/data/task.queue
TEMPLATES="virtual_host2 virtual_host2_sub virtual_host2_secure virtual_host2_secure_sub \
	ips_virtual_host redirect_virtual_host"
SCRIPTS="domain_create_post domain_destroy_post domain_change_post \
	subdomain_create_post subdomain_destroy_post \
	domain_pointer_create_post domain_pointer_destroy_post ssl_save_post \
	user_suspend_post user_activate_post user_modify_post user_destroy_post \
	ip_change_post ipsconf_write_post user_httpd_write_post \
	tally_rotation_post all_post"
MARKER_START="###ng-httpd autogenerated start###"
MARKER_END="###ng-httpd autogenerated end###"
EXTPORT=80
INTPORT=8888
EXTPORT_SSL=443
INTPORT_SSL=8889

ln_off='s/^\(\s*\)#*\s*/\1#/'
ln_on='s/^\(\s*\)#*\s*/\1/'
reload=false

add() {
	user=$1
	domain=$2

	if [[ -z $user || -z $domain ]]; then
		usage
		exit 1
	fi

	userdir=$DAUSERDIR/$user
	if [ ! -d $userdir ]; then
		echo "User not found"
		exit 1
	fi

	domconf=$userdir/domains/$domain.conf
	if [ ! -f $domconf ]; then
		echo "Domain not found"
		exit 1
	fi

	ip=$(grep "ip=" $domconf | cut -d= -f2)
	ips=$ip
	if [ -f $userdir/domains/$domain.ip_list ]; then
		ips=$(cat $userdir/domains/$domain.ip_list)
	fi
	ssl=$(grep -ic "ssl=on" $domconf)
	pro=$(egrep -ic "php=on|cgi=on" $domconf)

	alias=""
	pointer=""
	if [ -f $userdir/domains/$domain.pointers ]; then
		for ptr in $(cat $userdir/domains/$domain.pointers)
		do
			dom=$(echo $ptr | cut -d= -f1)
			type=$(echo $ptr | cut -d= -f2)
			if [ $type == "alias" ]; then
				alias="$alias.$dom "
			else
				pointer="$pointer $dom"
			fi
		done
	fi

	docroot=$(egrep -i "^DocumentRoot=" $domconf | cut -d= -f2)
	docroot_ssl=$(egrep -i "^SecureDocumentRoot=" $domconf | cut -d= -f2)
	if [ -z "$docroot" ]; then
		docroot=/home/$user/domains/$domain/public_html
		docroot_ssl=/home/$user/domains/$domain/private_html
	fi

	listen=""
	for ipp in $ips
	do
		listen="${listen}listen ${ipp}:80; "
	done

	sslconf=""
	if [ $ssl -gt 0 ]; then
		sslcert=$(grep -i "SSLCertificateFile=" $domconf | cut -d= -f2)
		sslkey=$(grep -i "SSLCertificateKeyFile=" $domconf | cut -d= -f2)
		if [ -z "$sslcert" ]; then
			sslcert=$(grep "apachecert=" /usr/local/directadmin/conf/directadmin.conf | cut -d= -f2)
			sslkey=$(grep "apachekey=" /usr/local/directadmin/conf/directadmin.conf | cut -d= -f2)
		fi
		sslconf="listen ${ip}:443 ssl; ssl_certificate $sslcert; ssl_certificate_key $sslkey;"
	fi

	proxy=""
	if [ $pro -gt 0 ]; then
		proxy="return 418;"
	fi

	resconf=$NGCONFDIR/vhost/$user-$domain.conf

	sed -e s/ADDR/$ip/g -e s/PORT_SSL/$INTPORT_SSL/g -e s/PORT/$INTPORT/g \
		-e s/DOCROOT_SSL/"${docroot_ssl//\//\/}"/g -e s/DOCROOT/"${docroot//\//\/}"/g \
		-e s/LISTEN/"$listen"/g -e s/PROXY/"${proxy}"/g -e s/SSL/"${sslconf//\//\/}"/g \
		-e s/USER/$user/g -e s/DOMAIN/$domain/g -e s/DOMLOG/$domain/g \
		-e s/ALIAS/"$alias"/g $NGCONFDIR/domain.conf > $resconf

	if [ -f $userdir/domains/$domain.subdomains ]; then
		for sub in $(cat $userdir/domains/$domain.subdomains)
		do
			subdocroot=$docroot/$sub
			subdocroot_ssl=$docroot_ssl/$sub
			subalias=""
			for als in $alias
			do
				subalias="$subalias .$sub$als"
			done

			sed -e s/ADDR/$ip/g -e s/PORT_SSL/$INTPORT_SSL/g -e s/PORT/$INTPORT/g \
				-e s/DOCROOT_SSL/"${subdocroot_ssl//\//\/}"/g -e s/DOCROOT/"${subdocroot//\//\/}"/g \
				-e s/LISTEN/"$listen"/g -e s/PROXY/"${proxy}"/g -e s/SSL/"${sslconf//\//\/}"/g \
				-e s/USER/$user/g -e s/DOMAIN/$sub.$domain/g -e s/DOMLOG/$domain.$sub/g \
				-e s/ALIAS/"$subalias"/g $NGCONFDIR/domain.conf >> $resconf
		done
	fi

	for ptr in $pointer
	do
		sed -e s/DOMAIN/$domain/g -e s/POINTER/$ptr/g -e s/LISTEN/"$listen"/g \
			$NGCONFDIR/pointer.conf >> $resconf
	done

	reload=true
}

delete() {
	user=$1
	domain=$2

	if [ -z $user ]; then
		usage
		exit 1
	fi

	if [ -z $domain ]; then
		rm -rf $NGCONFDIR/vhost/$user-*.conf
	else
		rm -rf $NGCONFDIR/vhost/$user-$domain.conf
	fi

	reload=true
}

build() {
	user=$1

	mkdir -p $NGCONFDIR/vhost
	if [ -z $user ]; then
		rm -rf $NGCONFDIR/vhost/*.conf
		userlist=$(ls -1 $DAUSERDIR)
	else
		delete $user
		userlist=$user
	fi

	for user in $userlist
	do
		if [ ! -d $DAUSERDIR/$user ]; then
			continue
		fi

		for domain in $(cat $DAUSERDIR/$user/domains.list)
		do
			add $user $domain
		done
	done

	reload=true
}

updateips() {
	sed -i -e s/:$EXTPORT/:$INTPORT/g -e s/:$EXTPORT_SSL/:$INTPORT_SSL/g $APCONFDIR/ips.conf
	ips=$(cat $DAROOTDIR/data/admin/ip.list | tr '\n' ' ')
	sed -i -e "/RemoteIPInternalProxy/I c\
RemoteIPInternalProxy $ips" -e "/RealIPProxy/I c\
RealIPProxy $ips" $APCONFDIR/extra/httpd-ng.conf

	default=$NGCONFDIR/extra/default.conf
	echo -n "" > $default
	for ip in $ips
	do
		sed s/ADDR/$ip/g $NGCONFDIR/default.conf >> $default
	done

	echo "action=httpd&value=restart" >> $DAQUEUE
	$DAROOTDIR/dataskq
	if [ $? != 0 ]; then
		echo "Apache restart failed"
		exit 1
	fi

	reload=true
}

enable() {
	cd $DATEMPDIR
	mkdir -p custom

	for tpl in $TEMPLATES
	do
		if [ ! -f custom/$tpl.conf ]; then
			cp $tpl.conf custom/
		fi
		if [[ "$tpl" == *_secure* ]]; then
			sed -i 's/ServerName\s\+\(https\?:\/\/\)\?/ServerName https:\/\//Ig' custom/$tpl.conf
		fi
		sed -i -e s/:$EXTPORT/:$INTPORT/g -e s/:$EXTPORT_SSL/:$INTPORT_SSL/g \
			-e "/CustomLog/I $ln_off" -e "/SSLEngine/I $ln_off" custom/$tpl.conf
	done

	cd $DAROOTDIR/scripts/custom
	for scr in $SCRIPTS
	do
		if [ ! -f $scr.sh ]; then
			echo "#!/bin/bash" > $scr.sh
		fi
		sed -i -e /nginx/d -e "/$MARKER_START/,/$MARKER_END/ d" $scr.sh
		chown diradmin:diradmin $scr.sh
		chmod 700 $scr.sh
	done

	echo 'echo "add $username $domain" >> /usr/local/nginx/sbin/queue' >> domain_create_post.sh
	echo 'echo "delete $username $domain" >> /usr/local/nginx/sbin/queue' >> domain_destroy_post.sh
	echo 'echo "delete $username $domain\nadd $username $newdomain" >> /usr/local/nginx/sbin/queue' >> domain_change_post.sh
	echo 'echo "add $username $domain" >> /usr/local/nginx/sbin/queue' >> subdomain_create_post.sh
	echo 'echo "add $username $domain" >> /usr/local/nginx/sbin/queue' >> subdomain_destroy_post.sh
	echo 'echo "add $username $domain" >> /usr/local/nginx/sbin/queue' >> domain_pointer_create_post.sh
	echo 'echo "add $username $domain" >> /usr/local/nginx/sbin/queue' >> domain_pointer_destroy_post.sh
	echo 'echo "add $username $domain" >> /usr/local/nginx/sbin/queue' >> ssl_save_post.sh
	echo 'echo "build $username" >> /usr/local/nginx/sbin/queue' >> user_suspend_post.sh
	echo 'echo "build $username" >> /usr/local/nginx/sbin/queue' >> user_activate_post.sh
	echo 'echo "build $username" >> /usr/local/nginx/sbin/queue' >> user_modify_post.sh
	echo 'echo "delete $username" >> /usr/local/nginx/sbin/queue' >> user_destroy_post.sh
	echo 'echo "build $username" >> /usr/local/nginx/sbin/queue' >> ip_change_post.sh
	echo 'echo "updateips" >> /usr/local/nginx/sbin/queue' >> ipsconf_write_post.sh
	echo '/etc/init.d/nginx flushlogs' >> tally_rotation_post.sh

	cat >> user_httpd_write_post.sh <<EOF
$MARKER_START
sed -i -e s/:$EXTPORT/:$INTPORT/g -e s/:$EXTPORT_SSL/:$INTPORT_SSL/g $DAUSERDIR/\$username/httpd.conf
$MARKER_END
EOF
	cat >> all_post.sh <<EOF
$MARKER_START
if [ "\$command" = "/CMD_DOMAIN" ] && ([ "\$action" = "modify" ] || [ -n "\$suspend" ]); then
	echo "build \$username" >> /usr/local/nginx/sbin/queue
fi
$MARKER_END
EOF

	echo "action=rewrite&value=ips" >> $DAQUEUE
	echo "action=rewrite&value=httpd" >> $DAQUEUE
	$DAROOTDIR/dataskq
	if [ $? != 0 ]; then
		echo "Apache config failed"
		exit 1
	fi

	sed -i -e s/$EXTPORT/$INTPORT/g -e "/httpd-ng/ $ln_on" $APCONFDIR/httpd.conf
	sed -i -e s/$EXTPORT_SSL/$INTPORT_SSL/g -e "/SSLEngine/I $ln_off" $APCONFDIR/extra/httpd-ssl.conf
	sed -i 's/KeepAlive\s\+On/KeepAlive Off/Ig' $APCONFDIR/extra/httpd-default.conf

	updateips
	build

	reload=false

	sed -i "s/nginx=OFF/nginx=ON/" $DAROOTDIR/data/admin/services.status
	/etc/init.d/nginx restart > /dev/null
	if [ $? != 0 ]; then
		echo "Nginx start failed"
		exit 1
	fi
}

disable() {
	sed -i "s/nginx=ON/nginx=OFF/" $DAROOTDIR/data/admin/services.status
	/etc/init.d/nginx stop > /dev/null
	if [ $? != 0 ]; then
		echo "Nginx stop failed"
		exit 1
	fi

	if [ -d $DATEMPDIR/custom ]; then
		cd $DATEMPDIR/custom

		for tpl in $TEMPLATES
		do
			if [ -f $tpl.conf ]; then
				sed -i -e s/:$INTPORT/:$EXTPORT/g -e s/:$INTPORT_SSL/:$EXTPORT_SSL/g \
					-e "/CustomLog/I $ln_on" -e "/SSLEngine/I $ln_on" $tpl.conf
			fi
		done
	fi

	cd $DAROOTDIR/scripts/custom
	for scr in $SCRIPTS
	do
		if [ -f $scr.sh ]; then
			sed -i -e /nginx/d -e "/$MARKER_START/,/$MARKER_END/ d" $scr.sh
		fi
	done

	sed -i -e s/$INTPORT/$EXTPORT/g -e "/httpd-ng/ $ln_off" $APCONFDIR/httpd.conf
	sed -i -e s/$INTPORT_SSL/$EXTPORT_SSL/g -e "/SSLEngine/I $ln_on" $APCONFDIR/extra/httpd-ssl.conf
	sed -i 's/KeepAlive\s\+Off/KeepAlive On/Ig' $APCONFDIR/extra/httpd-default.conf

	echo "action=rewrite&value=ips" >> $DAQUEUE
	echo "action=rewrite&value=httpd" >> $DAQUEUE
	echo "action=httpd&value=restart" >> $DAQUEUE
	$DAROOTDIR/dataskq
	if [ $? != 0 ]; then
		echo "Apache restart failed"
		exit 1
	fi
}

queue() {
	cd $CURDIR
	if [ ! -f queue ]; then
		touch queue
		chgrp diradmin queue
		chmod 664 queue
		exit 0
	fi

	while read line
	do
		$line
	done < queue

	echo -n "" > queue
}

usage() {
	echo "Usage:"
	echo "$0 add user domain"
	echo "$0 delete user [domain]"
	echo "$0 build [user]"
	echo "$0 (enable|disable|updateips|queue)"
}

#main
cmd=$1
user=$2
domain=$3

case $cmd in
	"add"		) add $user $domain;;
	"delete"	) delete $user $domain;;
	"build"		) build $user;;
	"enable"	) enable;;
	"disable"	) disable;;
	"updateips"	) updateips;;
	"queue"		) queue;;
	*		) usage;;
esac

if $reload; then
	/etc/init.d/nginx reload > /dev/null
	if [ $? != 0 ]; then
		echo "Nginx reload failed"
		exit 1
	fi
fi
