#!/bin/bash

umask 002

cd `dirname $0`

playerurl=http://radiko.jp/player/swf/player_3.0.0.01.swf
playerfile=./player.swf
keyfile=./authkey.png

if [ $# -ge 4 ]; then
  channel=$1
  stop=$(($2 * 60))
  name=$3
  artist=$4
  dir=$5
  album="Radio: $name"
else
  echo "usage : $0 channel_name duration_minutes name artist [dir_name]"
  exit 1
fi

#
# get player
#
if [ ! -f $playerfile ]; then
  wget -q -O $playerfile $playerurl

  if [ $? -ne 0 ]; then
    echo "failed get player"
    exit 1
  fi
fi

#
# get keydata (need swftool)
#
if [ ! -f $keyfile ]; then
  swfextract -b 14 $playerfile -o $keyfile

  if [ ! -f $keyfile ]; then
    echo "failed get keydata"
    exit 1
  fi
fi

#
# access auth1_fms
#
id="${channel}_${dir}_$(date +'%Y%m%d%H%M%S')"

rm -f "auth1_fms_${id}"
wget -q \
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
     -O "auth1_fms_${id}" \
     https://radiko.jp/v2/api/auth1_fms

if [ $? -ne 0 ]; then
  echo "failed auth1 process"
  exit 1
fi

#
# get partial key
#
authtoken=`cat "auth1_fms_${id}" | perl -ne 'print $1 if(/x-radiko-authtoken: ([\w-]+)/i)'`
offset=`cat "auth1_fms_${id}" | perl -ne 'print $1 if(/x-radiko-keyoffset: (\d+)/i)'`
length=`cat "auth1_fms_${id}" | perl -ne 'print $1 if(/x-radiko-keylength: (\d+)/i)'`

partialkey=`dd if=$keyfile bs=1 skip=${offset} count=${length} 2> /dev/null | base64`

echo "authtoken: ${authtoken} \noffset: ${offset} length: ${length} \npartialkey: $partialkey"

rm -f "auth1_fms_${id}"

#
# access auth2_fms
#
rm -f "auth2_fms_${id}"
wget -q \
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
     -O "auth2_fms_${id}" \
     https://radiko.jp/v2/api/auth2_fms

if [ $? -ne 0 -o ! -f "auth2_fms_${id}" ]; then
  echo "failed auth2 process"
  exit 1
fi

echo "authentication success"

areaid=`perl -ne 'print $1 if(/^([^,]+),/i)' auth2_fms_${id}`
echo "areaid: $areaid"

rm -f "auth2_fms_${id}"

#
# rtmpdump
#
title=`date +"${name} %Y-%m-%d"`
basename=`date +"/var/www/Music/${dir:+$dir/}${name}_${channel}_%Y-%m-%d_%H.%M.%S"`
flv="${basename}.flv"
m4a="${basename}.m4a"
mkdir -p "$(dirname "$basename")" # basename may contain '/'

retries=0
while :; do
  rtmpdump -q \
           -B $stop \
           -r "rtmpe://w-radiko.smartstream.ne.jp" \
           --playpath "simul-stream.stream" \
           --app "${channel}/_definst_" \
           -W $playerurl \
           -C S:"" -C S:"" -C S:"" -C S:$authtoken \
           --live \
           --flv "$flv"
  if [ $? -ne 1 -o `wc -c "$flv" | awk '{print $1}'` -ge 10240 ]; then
    break
  elif [ $retries -ge 5 ]; then
    echo "failed rtmpdump"
    exit 1
  else
    retries=$(($retries + 1))
    echo "rtmpdump retry: $retries"
  fi
done

ffmpeg -y -i "$flv" -vn -acodec copy \
       -metadata title="$title" \
       -metadata album="$album" \
       -metadata artist="$artist" \
       -metadata genre="Radio" \
       "$m4a" \
  && rm "$flv"
