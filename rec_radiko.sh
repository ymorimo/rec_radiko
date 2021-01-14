#!/bin/bash

umask 002

cd `dirname $0`

playerurl=https://radiko.jp/apps/js/flash/myplayer-release.swf
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


auth() {
    rm -f "playerCommon.$$"
    wget -q -O "playerCommon.$$" 'https://radiko.jp/apps/js/playerCommon.js?_=20171113'
    auth_key=`perl -ne "print \\$1 if (/new RadikoJSPlayer\(.*?'pc_html5',\s*'(\w+)'/)" playerCommon.$$`
    rm -f "playerCommon.$$"

    if [[ -z "$auth_key" ]]; then
        echo "retrieving auth_key from playerCommon.js failed"
        return 1
    fi

    rm -f "auth1.$$"
    wget -q \
        ${is_premium:+--load-cookies=$cookiesfile} \
        --header="pragma: no-cache" \
        --header="X-Radiko-App: pc_html5" \
        --header="X-Radiko-App-Version: 0.0.1" \
        --header="X-Radiko-User: test-stream" \
        --header="X-Radiko-Device: pc" \
        --no-check-certificate \
        --save-headers \
        --tries=5 \
        --timeout=5 \
        -O "auth1.$$" \
        https://radiko.jp/v2/api/auth1

    if [ $? -ne 0 ]; then
        echo "auth1 failed"
        return 1
    fi

    #
    # get partial key
    #
    authtoken=`perl -ne 'print $1 if(/x-radiko-authtoken: ([\w-]+)/i)' auth1.$$`
    offset=`perl -ne 'print $1 if(/x-radiko-keyoffset: (\d+)/i)' auth1.$$`
    length=`perl -ne 'print $1 if(/x-radiko-keylength: (\d+)/i)' auth1.$$`

    partialkey=`echo $auth_key | dd bs=1 skip=${offset} count=${length} 2> /dev/null | base64`

    # echo -e "authtoken: ${authtoken} \noffset: ${offset} length: ${length} \npartialkey: $partialkey"

    rm -f "auth1.$$"

    rm -f "auth2.$$"
    wget -q \
        ${is_premium:+--load-cookies=$cookiesfile} \
        --header="pragma: no-cache" \
        --header="X-Radiko-User: test-stream" \
        --header="X-Radiko-Device: pc" \
        --header="X-Radiko-Authtoken: ${authtoken}" \
        --header="X-Radiko-Partialkey: ${partialkey}" \
        --no-check-certificate \
        --tries=5 \
        --timeout=5 \
        -O "auth2.$$" \
        https://radiko.jp/v2/api/auth2

    if [ $? -ne 0 -o ! -f "auth2.$$" ]; then
        echo "auth2 failed"
        return 1
    fi

    areaid=`perl -ne 'print $1 if(/^([^,]+),/i)' auth2.$$`

    rm -f "auth2.$$"
}

record() {
    title=`date +"${name} %Y-%m-%d"`
    basename=`date +"$recordingdir/${dir:+$dir/}${name//\//-}_${station}_%Y-%m-%d_%H.%M.%S"`
    outfile="${basename}.m4a"
    tempfile="$recordingdir/recording.$$"
    mkdir -p "$(dirname "$basename")" # basename may contain '/'

    chunklist_url=$(curl -s -H "X-Radiko-Authtoken: $authtoken" "https://f-radiko.smartstream.ne.jp/$station/_definst_/simul-stream.stream/playlist.m3u8" | grep '^https://.*\.m3u8$' | head -1)

    if [[ -z "$chunklist_url" ]]; then
        echo "Couldn't get the chunklist URL."
        exit 1
    fi

    ffmpeg -loglevel quiet -nostats \
        -i "$chunklist_url" \
        -headers "X-Radiko-Authtoken: $authtoken" \
        -t $duration \
        -vn -acodec copy \
        -metadata title="$title" \
        -metadata album="$album" \
        -metadata artist="$artist" \
        -metadata genre="Radio" \
        -f mp4 "$tempfile"

    mv "$tempfile" "$outfile"
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
with_retries auth
record
[ -n "$is_premium" ] && with_retries premium_logout

# Local Variables:
# indent-tabs-mode: nil
# sh-basic-offset: 4
# sh-indentation: 4
# End:
