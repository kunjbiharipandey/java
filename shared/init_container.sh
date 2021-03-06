#!/usr/bin/env bash

cat >/etc/motd <<EOL 
  _____                               
  /  _  \ __________ _________   ____  
 /  /_\  \\___   /  |  \_  __ \_/ __ \ 
/    |    \/    /|  |  /|  | \/\  ___/ 
\____|__  /_____ \____/ |__|    \___  >
        \/      \/                  \/ 
A P P   S E R V I C E   O N   L I N U X
Documentation: http://aka.ms/webapp-linux

**NOTE**: No files or system changes outside of /home will persist beyond your application's current session. /home is your application's persistent storage and is shared across all the server instances.


EOL
cat /etc/motd

echo "Setup openrc ..." && openrc && touch /run/openrc/softlevel

echo Updating /etc/ssh/sshd_config to use PORT $SSH_PORT
sed -i "s/SSH_PORT/$SSH_PORT/g" /etc/ssh/sshd_config

echo Starting ssh service...
rc-service sshd start

# Enable case-insensitive string matching
shopt -s nocasematch

# COMPUTERNAME will be defined uniquely for each worker instance while running in Azure.
# If COMPUTERNAME isn't available, we assume that the container is running in a dev environment.
# If running in dev environment, define required environment variables.
if [ -z "$COMPUTERNAME" ]
then
    export COMPUTERNAME=dev

    # BEGIN: AzMon related environment variables
    export HTTP_LOGGING_ENABLED=1
    export WEBSITE_HOSTNAME=dev.appservice.com
    export APPSETTING_WEBSITE_AZMON_ENABLED=True
    # END: AzMon related environment variables
fi

# Variables in logging.properties aren't being evaluated, so explicitly update logging.properties with the appropriate values
sed -i "s/__PLACEHOLDER_COMPUTERNAME__/$COMPUTERNAME/" /tmp/appservice/logging.properties

# BEGIN: Configure Spring Boot properties
# Precedence order of properties can be found here: https://docs.spring.io/spring-boot/docs/current/reference/html/boot-features-external-config.html

export SERVER_PORT=$PORT
# Increase the default size so that Easy Auth headers don't exceed the size limit
export SERVER_MAXHTTPHEADERSIZE=16384
export LOGGING_FILE=/home/LogFiles/Application/spring.$COMPUTERNAME.log

# END: Configure Spring Boot properties

# BEGIN: Configure Java properties

export JAVA_OPTS="$JAVA_OPTS -noverify"
export JAVA_TOOL_OPTIONS="$JAVA_TOOL_OPTIONS -Djava.net.preferIPv4Stack=true"

# *** NOTE: WEBSITE_AZMON_PREVIEW_ENABLED is for Spring Boot / AzMon internal testing purposes only and will be removed soon ***
if [[ "$WEBSITE_AZMON_PREVIEW_ENABLED" = "1" ||  "$WEBSITE_AZMON_PREVIEW_ENABLED" = "true" ]]
then
    echo Performing AzMon configuration
    export JAVA_OPTS="$JAVA_OPTS -Djava.util.logging.config.file=/tmp/appservice/logging.properties"
else
    echo Skipping AzMon configuration
fi

# END: Configure Java properties

# BEGIN: Configure /etc/profile

eval $(printenv | sed -n "s/^\([^=]\+\)=\(.*\)$/export \1=\2/p" | sed 's/"/\\\"/g' | sed '/=/s//="/' | sed 's/$/"/' >> /etc/profile)

# We want all ssh sesions to start in the /home directory
echo "cd /home" >> /etc/profile

# END: Configure /etc/profile

# BEGIN: Process startup file / startup command, if any

DEFAULT_STARTUP_FILE=/home/startup.sh
STARTUP_FILE=
STARTUP_COMMAND=

# The web app can be configured to run a custom startup command or a custom startup script
# This custom command / script will be available to us as a param ($1, $2, ...)
#
# IF $1 is a non-empty string AND an existing file, we treat $1 as a startup file (and ignore $2, $3, ...)
# IF $1 is a non-empty string BUT NOT an existing file, we treat $@ (equivalent of $1, $2, ... combined) as a startup command
# IF $1 is an empty string AND $DEFAULT_STARTUP_FILE exists, we use it as the startup file
# ELSE, we skip running the startup script / command
#
if [ -n "$1" ] # $1 is a non-empty string
then
    if [ -f "$1" ] # $1 file exists
    then
        STARTUP_FILE=$1
    else
        STARTUP_COMMAND=$@
    fi
elif [ -f $DEFAULT_STARTUP_FILE ] # Default startup file path exists
then
    STARTUP_FILE=$DEFAULT_STARTUP_FILE
fi

echo STARTUP_FILE=$STARTUP_FILE
echo STARTUP_COMMAND=$STARTUP_COMMAND

# If $STARTUP_FILE is a non-empty string, we need to run the startup file
if [ -n "$STARTUP_FILE" ]
then

    # Copy startup file to a temporary location and fix the EOL characters in the temp file (to avoid changing the original copy)
    TMP_STARTUP_FILE=/tmp/startup.sh
    echo Copying $STARTUP_FILE to $TMP_STARTUP_FILE and fixing EOL characters in $TMP_STARTUP_FILE
    cp $STARTUP_FILE $TMP_STARTUP_FILE
    dos2unix $TMP_STARTUP_FILE
    
    echo Running STARTUP_FILE: $TMP_STARTUP_FILE
    source $TMP_STARTUP_FILE
    # Capture the exit code before doing anything else
    EXIT_CODE=$?
    echo Finished running startup file \'$TMP_STARTUP_FILE\'. Exiting with exit code $EXIT_CODE.
    exit $EXIT_CODE
else
    echo No STARTUP_FILE available.
fi

if [ -n "$STARTUP_COMMAND" ]
then
    echo Running STARTUP_COMMAND: "$STARTUP_COMMAND"
    $STARTUP_COMMAND
    # Capture the exit code before doing anything else
    EXIT_CODE=$?
    echo Finished running startup command \'$STARTUP_COMMAND\'. Exiting with exit code $EXIT_CODE.
    exit $EXIT_CODE
else
    echo No STARTUP_COMMAND defined.
fi

# END: Process startup file / startup command, if any

# If no app is published at /home/site/wwwroot/app.jar, use the parking page app.
# If an app is published, the default behavior is to copy the app to a local location, unless:
# 1. WEBSITE_SKIP_LOCAL_COPY is defined to 1 or TRUE, OR,
# 2. Local cache is enabled, in which case making a local copy again is unnecessary.
if [ ! -f /home/site/wwwroot/app.jar ]
then
    APP_JAR_PATH=/tmp/appservice/parkingpage.jar
    echo "Using parking page app with APP_JAR_PATH=$APP_JAR_PATH"
elif [[ "$WEBSITE_LOCAL_CACHE_OPTION" = "Always" || "$WEBSITE_SKIP_LOCAL_COPY" = "1"  || "$WEBSITE_SKIP_LOCAL_COPY" = "true" ]]
then
    APP_JAR_PATH=/home/site/wwwroot/app.jar
    echo "No local copy needed. APP_JAR_PATH=$APP_JAR_PATH"
else
    mkdir -p /local/site
    cp -r /home/site/wwwroot /local/site/wwwroot
    APP_JAR_PATH=/local/site/wwwroot/app.jar
    echo "Made a local copy of the app and using APP_JAR_PATH=$APP_JAR_PATH"
fi

# *** NOTE: WEBSITE_AZMON_PREVIEW_ENABLED is for Spring Boot / AzMon internal testing purposes only and will be removed soon ***
if [[ "$WEBSITE_AZMON_PREVIEW_ENABLED" = "1" ||  "$WEBSITE_AZMON_PREVIEW_ENABLED" = "true" ]]
then
    CMD="java -cp $APP_JAR_PATH:/tmp/appservice/azure.appservice.jar $JAVA_OPTS org.springframework.boot.loader.PropertiesLauncher $SPRINGBOOT_OPTS"
else
    CMD="java $JAVA_OPTS -jar $APP_JAR_PATH"
fi

echo Running command: "$CMD"
$CMD
