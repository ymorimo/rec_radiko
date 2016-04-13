#!/bin/bash

umask 002

cd `dirname $0`

playerurl=http://radiko.jp/player/swf/player_4.1.0.00.swf
playerfile=./player.swf
keyfile=./authkey.png
cookiesfile="./cookies.${pid}"

recordingdir=${RADIKO_OUTDIR:-.}

premium_login() {
    # echo -n 'Logging in to Radiko Premium... '

    if [ -z "$RADIKO_EMAIL" -o -z "$RADIKO_PASSWORD" ]; then
        echo "Set RADIKO_EMAIL and RADIKO_PASSWORD to log in to Radiko Premium"
        exit 1
    fi

    wget -q \
         --no-check-certificate \
         --save-cookies=$cookiesfile \
         --keep-session-cookies \
         --post-data="mail=$RADIKO_EMAIL&pass=$RADIKO_PASSWORD" \
         --save-headers \
         -O /dev/null \
         https://radiko.jp/ap/member/login/login

    if [ $? -ne 0 ]; then
        echo "login failed"
        return 1
    fi

    trap 'trapped=true; premium_logout' SIGTERM SIGINT

    # check login
    wget -q \
         --load-cookies=$cookiesfile \
         --save-headers \
         -O /dev/null \
         https://radiko.jp/ap/member/webapi/member/login/check

    if [ $? -ne 0 ]; then
        echo "login/check failed"
        return 1
    fi

    # echo 'ok'
}

premium_logout() {
    if [ -f $cookiesfile ]; then
        wget -q \
             --no-check-certificate \
             --load-cookies=$cookiesfile \
             --save-headers \
             -O /dev/null \
             https://radiko.jp/ap/member/webapi/member/logout
        rm -f $cookiesfile
        trap - SIGTERM SIGINT
        # echo 'Logged out from radiko.jp'
    fi
}


#
# get player
#
get_player() {
    if [ ! -f $playerfile ]; then
        wget -q -O $playerfile $playerurl

        if [ $? -ne 0 ]; then
            echo "get_player failed"
            return 1
        fi
    fi
}

#
# get keydata (need swftool)
#
get_keydata() {
    if [ ! -f $keyfile ]; then
        swfextract -b 14 $playerfile -o $keyfile

        if [ ! -f $keyfile ]; then
            echo "get_keydata failed"
            return 1
        fi
    fi
}

#
# access auth1_fms
#
auth1() {
    rm -f "auth1_fms.$$"
    wget -q \
        ${is_premium:+--load-cookies=$cookiesfile} \
        --header="pragma: no-cache" \
        --header="X-Radiko-App: pc_1" \
        --header="X-Radiko-App-Version: 2.0.1" \
        --header="X-Radiko-User: test-stream" \
        --header="X-Radiko-Device: pc" \
        --post-data='\r\n' \
        --no-check-certificate \
        --save-headers \
        --tries=5 \
        --timeout=5 \
        -O "auth1_fms.$$" \
        https://radiko.jp/v2/api/auth1_fms

    if [ $? -ne 0 ]; then
        echo "auth1 failed"
        return 1
    fi

    #
    # get partial key
    #
    authtoken=`perl -ne 'print $1 if(/x-radiko-authtoken: ([\w-]+)/i)' auth1_fms.$$`
    offset=`perl -ne 'print $1 if(/x-radiko-keyoffset: (\d+)/i)' auth1_fms.$$`
    length=`perl -ne 'print $1 if(/x-radiko-keylength: (\d+)/i)' auth1_fms.$$`

    partialkey=`dd if=$keyfile bs=1 skip=${offset} count=${length} 2> /dev/null | base64`

    # echo -e "authtoken: ${authtoken} \noffset: ${offset} length: ${length} \npartialkey: $partialkey"

    rm -f "auth1_fms.$$"
}

#
# access auth2_fms
#
auth2() {
    rm -f "auth2_fms.$$"
    wget -q \
        ${is_premium:+--load-cookies=$cookiesfile} \
        --header="pragma: no-cache" \
        --header="X-Radiko-App: pc_1" \
        --header="X-Radiko-App-Version: 2.0.1" \
        --header="X-Radiko-User: test-stream" \
        --header="X-Radiko-Device: pc" \
        --header="X-Radiko-Authtoken: ${authtoken}" \
        --header="X-Radiko-Partialkey: ${partialkey}" \
        --post-data='\r\n' \
        --no-check-certificate \
        --tries=5 \
        --timeout=5 \
        -O "auth2_fms.$$" \
        https://radiko.jp/v2/api/auth2_fms

    if [ $? -ne 0 -o ! -f "auth2_fms.$$" ]; then
        echo "auth2 failed"
        return 1
    fi

    areaid=`perl -ne 'print $1 if(/^([^,]+),/i)' auth2_fms.$$`

    rm -f "auth2_fms.$$"
}

record() {
    #
    # get stream-url
    #
    if [ -f ${station}.xml ]; then
        rm -f ${station}.xml
    fi

    wget -q "http://radiko.jp/v2/station/stream/${station}.xml"

    stream_url=`echo "cat /url/item[1]/text()" | xmllint --shell ${station}.xml | tail -2 | head -1`
    url_parts=(`echo ${stream_url} | perl -pe 's!^(.*)://(.*?)/(.*)/(.*?)$/!$1://$2 $3 $4!'`)

    rm -f ${station}.xml

    #
    # rtmpdump
    #
    title=`date +"${name} %Y-%m-%d"`
    basename=`date +"$recordingdir/${dir:+$dir/}${name//\//-}_${station}_%Y-%m-%d_%H.%M.%S"`
    flv="${basename}.flv"
    m4a="${basename}.m4a"
    mkdir -p "$(dirname "$basename")" # basename may contain '/'

    rtmpdump -q \
        -r ${url_parts[0]} \
        --app ${url_parts[1]} \
        --playpath ${url_parts[2]} \
        -W $playerurl \
        -C S:"" -C S:"" -C S:"" -C S:$authtoken \
        --live \
        --stop ${duration} \
        --flv "$flv"

    if [ $? -eq 1 -o `wc -c "$flv" | awk '{print $1}'` -lt 10240 ]; then
        echo 'rtmpdump failed'
        return 1
    fi

    ffmpeg -loglevel quiet \
        -y -i "$flv" -vn -acodec copy \
        -metadata title="$title" \
        -metadata album="$album" \
        -metadata artist="$artist" \
        -metadata genre="Radio" \
        "$m4a"

    if [ $? -eq 0 ]; then
        rm "$flv"
        # echo "Recording done: "${dir:+$dir/}$(basename "$m4a")
    fi
}


with_retries() {
    cmd=$1
    retries=0
    while :; do
        $cmd
        if [ $? -eq 0 ]; then
            break
        elif [ $retries -ge 10 ]; then
            echo "\`$cmd\` failed after 10 retries"
            premium_logout
            exit 1
        else
            retries=$(($retries + 1))
            echo "Retrying \`$cmd\` after sleeping $retries seconds"
            sleep $retries
        fi
        if [ -n "$trapped" ]; then break; fi
    done
}


usage_exit() {
    echo "Usage: $0 [-p] station_id duration_minutes name artist [subdir]"
    echo "  -p: Log in to Radiko Premium. Email and password are read from environment variables, RADIKO_EMAIL and RADIKO_PASSWORD."
    exit 1
}


while getopts p opt; do
    case $opt in
        p) is_premium='true'
           ;;
        *) usage_exit
           ;;
    esac
done
shift $((OPTIND - 1))

#
# main
#
if [ $# -ge 4 ]; then
    station=$1
    duration=$(($2 * 60))
    name=$3
    artist=$4
    dir=$5
    album="Radio: $name"
else
    usage_exit
fi

[ -n "$is_premium" ] && with_retries premium_login
with_retries get_player
with_retries get_keydata
with_retries auth1
with_retries auth2
with_retries record
[ -n "$is_premium" ] && with_retries premium_logout

# Local Variables:
# indent-tabs-mode: nil
# sh-basic-offset: 4
# sh-indentation: 4
# End:
