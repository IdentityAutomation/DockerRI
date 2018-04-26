#!/bin/bash

# check for arguments
if [[ $# -eq 0 ]] ; then
    echo 'Missing arguments.  Use -h (or --help) for help.'
    exit 0
fi

# variable initialization
SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_PATH="$(dirname "$SCRIPT_PATH")"
DSSPROJECT_CONFIGS="$BASE_PATH/configs/dssproject"
SQL_CONFIGS="$BASE_PATH/configs/sql"
LOG_FILE="$BASE_PATH/install.log"
touch $LOG_FILE
echo "" > $LOG_FILE


# menu controller
echo 'Validating command parameters...' >> $LOG_FILE
DEMO=false
while [ $# -gt 0 ]
do
	case "$1" in
		-h|--help)	
			echo 'Found help parameter' >> $LOG_FILE
			echo 'Usage: dockerRI COMMAND'
			echo ' '
			echo 'Personal script to manage RapidIdentity deployment in docker.'
			echo ' '
			echo 'Options:'
			echo '	-h, --help           View help page (this page)'
			echo '	-a, --action string  Action to take:'
			echo '                         clean    Removes ALL docker artifacts'
			echo '                         new      Deploys all new RI containers'
			echo '                         update   Updates RI container ONLY'
			echo '                         load     Loads demo data into existing deployment'
			echo '	-i, --image string   RapidIdentity image to use:'
			echo '                         stable   Stable rolling build'
			echo '                         nightly  Nightly rolling build'
			echo '                         beta     Current UI Beta 2018-4-6'
			echo '	-p, --profile string AWS profile to use.  Only needed for new and update actions'
			echo '	-d, --demo [stage] When present demo data will be loaded ONLY with new action.'
			echo '                         Optional stage number specifies which Demo Stage will be pre-loaded.'
			echo '                             0 => Employee data generated and populated'
			echo '                             1 => Delegation definitions updated'
			echo '                             2 => Roles and system roles created and updated'
			echo '                             3 => TBD'
			exit
			;;
		-a|--action)
			PARAM='action'
			echo "Evaluating $PARAM parameter..." >> $LOG_FILE
			if [ -z "$2" ] ; then
				MESSAGE="Missing $PARAM parameter value.  Use -h (or --help) for help."
				echo $MESSAGE
				echo $MESSAGE >> $LOG_FILE
				exit 0
			fi
			if [ "$2" != 'clean' ] && [ "$2" != 'new' ] && [ "$2" != 'update' ] && [ "$2" != 'load' ] ; then
				MESSAGE="Invalid $PARAM parameter value.  Use -h (or --help) for help."
				echo $MESSAGE
				echo $MESSAGE >> $LOG_FILE
				exit 0
			fi
    		ACTIONPARAM="$2"
			echo "The $PARAM parameter value is $2..." >> $LOG_FILE
    		shift # past argument
    		shift # past value
			;;
		-i|--image)
			PARAM='image'
			echo "Evaluating $PARAM parameter..." >> $LOG_FILE
			if [ -z "$2" ] ; then
				MESSAGE="Missing $PARAM parameter value.  Use -h (or --help) for help."
				echo $MESSAGE
				echo $MESSAGE >> $LOG_FILE
				exit 0
			fi
			if [ "$2" != 'stable' ] && [ "$2" != 'nightly' ] && [ "$2" != 'beta' ] ; then
				MESSAGE="Invalid $PARAM parameter value.  Use -h (or --help) for help."
				echo $MESSAGE
				echo $MESSAGE >> $LOG_FILE
				exit 0
			fi
			echo "The $PARAM parameter value is $2..." >> $LOG_FILE
			if [ "$2" == "beta" ] ; then
				IMAGEPARAM="beta-ui-2018-4-6"
			elif [[ "$2" == "stable" ]]; then
				IMAGEPARAM="rolling"
			elif [[ "$2" == "nightly" ]]; then
				IMAGEPARAM="rolling-nightly"
			else
				IMAGEPARAM="$2"
			fi
    		shift # past argument
    		shift # past value
			;;
		-p|--profile)
			PARAM='profile'
			echo "Evaluating $PARAM parameter..." >> $LOG_FILE
			if [ -z "$2" ] ; then
				MESSAGE="Missing $PARAM parameter value.  Use -h (or --help) for help."
				echo $MESSAGE
				echo $MESSAGE >> $LOG_FILE
				exit 0
			fi
			PROFILEPARAM="$2"
			echo "The $PARAM parameter value is $2..." >> $LOG_FILE
    		shift # past argument
    		shift # past value
			;;
		-d|--demo)
			PARAM='demo'
			DEMO=true
			echo "Evaluating $PARAM parameter..." >> $LOG_FILE
			if ! [[ "$2" =~ ^[0-9]+$ ]] ; then
				echo "The $PARAM parameter value is 0..." >> $LOG_FILE
				DEMOPARAM=0
			else
				echo "The $PARAM parameter value is $2..." >> $LOG_FILE
				DEMOPARAM="$2"
				shift
			fi
			shift
			;;
		*)
			PARAM='unknown'
			echo "Evaluating $PARAM parameter..." >> $LOG_FILE
			MESSAGE="Invalid parameter found.  Use -h (or --help) for help."
			echo $MESSAGE
			echo $MESSAGE >> $LOG_FILE
			exit 0
	esac
done

clean_all() {
	if [[ $(docker ps --quiet) ]] ; then
		docker kill $(docker ps --quiet)
	fi
	if [[ $(docker volume ls --quiet) ]] ; then
		docker volume rm $(docker volume ls --quiet)
	fi
	docker system prune -a
}

aws_authn() {
	# authenticate to ECR using the above configured profile
	$(aws ecr get-login --profile $PROFILEPARAM --no-include-email)	
}

load_demo_data() {
	for filePath in $DSSPROJECT_CONFIGS/*
	do
		fileName="${filePath##*/}"
		projectName="${fileName%.*}"
		# upload setup project
		curl -H "Content-Type: application/octet-stream" \
			--data-binary "@$filePath" \
			-X POST \
			-u admin:secret \
			--insecure \
			--silent \
			"https://127.0.0.1:18443/api/rest/admin/connect/importProject/$projectName" > /dev/null
	done

	# run setup.Init action set
	if [ -z "$DEMOPARAM" ] ; then
		curl -H "Content-Type: application/json" \
			-X GET \
			-u admin:secret \
			--insecure \
			--silent \
			"https://127.0.0.1:18443/api/rest/admin/connect/runForValue/setup.Init?arg-stage=0" > /dev/null
	else
		curl -H "Content-Type: application/json" \
			-X GET \
			-u admin:secret \
			--insecure \
			--silent \
			"https://127.0.0.1:18443/api/rest/admin/connect/runForValue/setup.Init?arg-stage=$DEMOPARAM"
	fi		
}

deploy_postgres() {
	# download database container
	docker pull postgres:9.6.8
	docker volume create pgdata968
	# start container (You'll want to put this in a script to start when needed)
	docker run -d --rm  \
	    --name postgresql \
	    -p 15432:5432 \
	    -v pgdata968:/var/lib/postgresql/data \
	    postgres:9.6.8
	sleep 15
	#add idautoAdmin user and idautodb
	curl -q https://s3.amazonaws.com/idauto-apps/postgres.sql.bz2 | \
		bunzip2 | \
		docker exec -i postgresql psql -U postgres
	sleep 5
}

deploy_openldap() {
	# create persistent volume for openldap
	docker volume create openldap	
	# download openldap container
	docker pull 071093231757.dkr.ecr.us-east-1.amazonaws.com/idauto-openldap:latest
	docker tag 071093231757.dkr.ecr.us-east-1.amazonaws.com/idauto-openldap:latest idauto-openldap:latest
	# start openldap (You'll want to put this in a script to start when needed)
	docker run -d --rm \
	    --name openldap \
	    -p 18389:389 \
	    -p 18636:636 \
	    -v openldap:/var/openldap \
	    idauto-openldap:latest
	sleep 5	
}

deploy_rapididentity() {
	# deploy demo database before RI
	if $DEMO ; then
		cat $SQL_CONFIGS/public.sql | \
			docker exec -i postgresql psql -U idautoAdmin -d idautodb
	fi
	# download appropriate RapidIdentity container
	docker pull 071093231757.dkr.ecr.us-east-1.amazonaws.com/rapididentity:$IMAGEPARAM
	docker tag 071093231757.dkr.ecr.us-east-1.amazonaws.com/rapididentity:$IMAGEPARAM rapididentity:latest
	# create persistent volume for shared files
	docker volume create ri-wfmAttachements
	docker volume create ri-icons
	docker volume create ri-images
	docker volume create ri-commonlib
	docker volume create ri-dssfiles
	docker volume create ri-dssprojects 
	# start RapidIdentity (You'll want to put this in a script to start when needed)
	docker run -d --rm \
	    --name rapididentity \
	    -p 18443:8443 \
	    -p 18080:8080 \
	    -v ri-wfmAttachments:/var/opt/idauto/wfmAttachements \
	    -v ri-icons:/var/opt/idauto/icons \
	    -v ri-images:/var/opt/idauto/apps/images \
	    -v ri-commonlib:/var/opt/idauto/common/lib \
	    -v ri-dssfiles:/var/opt/idauto/dss/files \
	    -v ri-dssprojects:/var/opt/idauto/dss/projects \
	    rapididentity:latest \
	        -XX:+UnlockExperimentalVMOptions \
	        -XX:+UseCGroupMemoryLimitForHeap \
	        -Dcapabilities=admin,portal,federation,connect \
	        -Djmx.username=admin \
	        -Djmx.password=admin \
	        -Djmx.hostname=localhost\
	        -Ddb.type=postgresql \
	        -Ddb.host=host.docker.internal \
	        -Ddb.port=15432
	sleep 5
	# set the password sync primary key
	docker exec -it openldap /var/opt/idauto/openldap/setPublicKey.sh host.docker.internal:18080
	# update ldap server settings
}

deploy_new() {
	if [ -z "$PROFILEPARAM" ] ; then
		echo 'Missing profile parameter.  Use -h (or --help) for help.'
		exit 0
	fi
	if [ -z "$IMAGEPARAM" ] ; then
		echo 'Missing image parameter.  Use -h (or --help) for help.'
		exit 0
	fi

	# aws authentication to ecr
	aws_authn
	# deploy postgres container
	deploy_postgres
	# deploy openldap container
	deploy_openldap
	# deploy rapididentity container
	deploy_rapididentity
	# deploy demo data
	if $DEMO ; then
		load_demo_data
	fi
	echo ' '
	echo 'Container to container communications should use host.docker.internal hostname'
	echo ' '
	echo 'Access RapidIdentity at https://localhost:18443'
	open https://localhost:18443
}

deploy_update() {
	if [[ $(docker ps --filter name=rapididentity --quiet) ]] ; then
		docker kill $(docker ps --filter name=rapididentity --quiet)
	fi
	if [ -z "$PROFILEPARAM" ] ; then
		echo 'Missing profile parameter.  Use -h (or --help) for help.'
		exit 0
	fi
	if [ -z "$IMAGEPARAM" ] ; then
		echo 'Missing image parameter.  Use -h (or --help) for help.'
		exit 0
	fi
	# aws authentication to ecr
	aws_authn # function
	# deploy rapididentity container
	deploy_rapididentity # function
	echo ' '
	echo 'Access RapidIdentity at https://localhost:18443'
}

# perform actions
case "$ACTIONPARAM" in
	clean)
		clean_all
		;;
	new)
		deploy_new
		;;
	update)
		deploy_update
		;;
	load)
		load_demo_data
		;;
	*)
		echo "Invalid parameters.  Use -h (or --help) for help." > $LOG_FILE

esac

echo ' '
echo 'Success.  Bye.'

