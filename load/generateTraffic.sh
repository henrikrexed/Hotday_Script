#!/bin/bash
###########################################################################################################
####  Required Environment variable :
#### duration duration of the test in seconds( default 120)
#### thinktime thinktime in seconds  (default 5)
#########################################################################################################
while [ $# -gt 0 ]; do
  case "$1" in
  --duration)
    duration="$2"
    shift 2
    ;;
  --thinktime)
    thinktime="$2"
    shift 2
    ;;
  *)
    echo "Warning: skipping unsupported option: $1"
    shift
    ;;
  esac
done

if [ -z "$duration" ]; then
  duration=120
else
  if [ $duration -lt 1 ]
  then
    duration=120
  fi
fi

if [ -z "$thinktime" ]; then
  thinktime=5
else
  if [ $thinktime -lt 1 ]
  then
    thinktime=5
  fi
fi



###################################################
# set variables used by script
###################################################

# url to the order app
url="http://$(kubectl get ingress onlineboutique-ingress -n hipster-shop -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' )"
host="onlineboutique.domain.com"
# Set Dynatrace Test Headers Values
loadScriptName="loadtest.sh"

# Calculate how long this test maximum runs!
thinktime=5  # default the think time
currTime=`date +%s`
timeSpan=$duration
endTime=$(($timeSpan+$currTime))


#######################
##  Define data set
##
########################
product[0]="OLJCESPC7Z"
product[1]="66VCHSJNUP"
product[2]="1YMWWN1N4O"
product[3]="2ZYFJ3GM2N"
product[4]="0PUK6V6EV0"
product[5]="LS4PSXUNUM"
product[6]="9SIQT8TOJO"
product[7]="6E92ZMYYFZ"
size=${#product[@]}

###################################################
# Run test
###################################################



echo "Load Test Started. NAME: $loadTestName"
echo "DURATION=$duration URL=$url THINKTIME=$thinktime host=$host"


# loop until run out of time.  use thinktime between loops
while [ $currTime -lt $endTime ];
do
  currTime=`date +%s`
  echo "Loop Start: $(date +%H:%M:%S)"

  testStepName="Home Page"
  echo "  calling TSN=$testStepName; $(curl -s "$url" -w "%{http_code}" -H "Host: $host"  -o /dev/nul)"
  sleep $thinktime
  testStepName="product"
  index=$(($RANDOM % $size))
  echo "  calling TSN=$testStepName; $(curl -s "$url/product/${product[$index]}" -w "%{http_code}" -H "Host: $host"   -o /dev/nul)"
  sleep $thinktime
  testStepName="cart"
  echo "  calling TSN=$testStepName; $(curl -s "$url/cart" -w "%{http_code}" -H "Host: $host"  -o /dev/nul)"
  sleep $thinktime
done;

echo Done.
