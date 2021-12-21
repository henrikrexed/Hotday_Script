#!/bin/sh
###########################################################################################################
####  Required Environment variable :
#### ENVIRONMENT_URL=<with your environment URL (without 'http'). Example: {your-environment-id}.live.dynatrace.com> or {your-domain}/e/{your-environment-id}
#### ENVIRONMENT_ID= Example: {your-environment-id}.live.dynatrace.com> , https://{your-domain}/e/{your-environment-id}/
#### API_TOKEN : api token with the following right : metric ingest, trace ingest, and log ingest and Access problem and event feed, metrics and topology
#### PAAS_TOKEN paas token
#### BASTION_USER: linux user created for the bastion host
#########################################################################################################
while [ $# -gt 0 ]; do
  case "$1" in
  --environment-url)
    ENVIRONMENT_URL="$2"
    shift 2
    ;;
  --api-token)
    API_TOKEN="$2"
    shift 2
    ;;
  --paas-token)
    PAAS_TOKEN="$2"
    shift 2
    ;;
  --environmentid)
    ENVIRONMENT_ID="$2"
    shift 2
    ;;
   --bastion-user)
    BASTION_USER="$2"
    shift 2
    ;;
  *)
    echo "Warning: skipping unsupported option: $1"
    shift
    ;;
  esac
done

if [ -z "$ENVIRONMENT_URL" ]; then
  echo "Error: environment-url not set!"
  exit 1
fi

if [ -z "$ENVIRONMENT_ID" ]; then
  echo "Error: environmentid not set!"
  exit 1
fi

if [ -z "$API_TOKEN" ]; then
  echo "Error: api-token not set!"
  exit 1
fi

if [ -z "$PAAS_TOKEN" ]; then
  echo "Error: paas-token not set!"
  exit 1
fi

if [ -z "$BASTION_USER" ]; then
  echo "Error: BASTION_USER not set!"
  exit 1
fi


CLUSTER_NAME="hotday"
K8S_ENDPOINT="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
if [ -z "$K8S_ENDPOINT" ]; then
  echo "Error: failed to get kubernetes endpoint!"
  exit 1
fi

apiRequest() {
  method=$1
  url=$2
  json=$3

  curl_command="curl -k"
  response="$(${curl_command} -sS -X ${method} "https://${ENVIRONMENT_URL}/api${url}" \
    -H "accept: application/json; charset=utf-8" \
    -H "Authorization: Api-Token ${API_TOKEN}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "${json}")"

  echo "$response"
}


###Deploy dynatrace operator
printf "\nDeployment of the Dynatrace Operator...\n"
kubectl label namespace default monitor=dynatrace
kubectl create namespace dynatrace
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/latest/download/kubernetes-csi.yaml
kubectl -n dynatrace create secret generic dynakube --from-literal="apiToken=$API_TOKEN" --from-literal="paasToken=$PAAS_TOKEN"
sed -i "s,ENVIRONMENT_URL,$ENVIRONMENT_URL," /home/$BASTION_USER/hotday_script/dynatrace/dynakube.yaml
kubectl -n dynatrace wait pod --for=condition=ready -l internal.dynatrace.com/app=webhook --timeout=300s
kubectl apply -n dynatrace -f /home/$BASTION_USER/hotday_script/dynatrace/dynakube.yaml
K8S_SECRET_NAME="$(for token in $(kubectl get sa dynatrace-kubernetes-monitoring -o jsonpath='{.secrets[*].name}' -n dynatrace); do echo "$token"; done | grep -F token)"
  if [ -z "$K8S_SECRET_NAME" ]; then
    echo "Error: failed to get kubernetes-monitoring secret!"
    exit 1
  fi

K8S_BEARER="$(kubectl get secret "${K8S_SECRET_NAME}" -o jsonpath='{.data.token}' -n dynatrace | base64 --decode)"
if [ -z "$K8S_BEARER" ]; then
  echo "Error: failed to get bearer token!"
  exit 1
fi

json="$(
      cat <<EOF
{
  "label": "${CLUSTER_NAME}",
  "endpointUrl": "${K8S_ENDPOINT}",
  "eventsFieldSelectors": [
    {
      "label": "Node events",
      "fieldSelector": "involvedObject.kind=Node",
      "active": true
    },
    {
      "label": "Pod events",
      "fieldSelector": "involvedObject.kind=Pod",
      "active": true
    }
  ],
  "workloadIntegrationEnabled": true,
  "eventsIntegrationEnabled": true,
  "activeGateGroup": "default",
  "authToken": "${K8S_BEARER}",
  "active": true,
  "certificateCheckEnabled": false,
  "hostnameVerificationEnabled": false,
  "prometheusExportersIntegrationEnabled": true,
  "davisEventsIntegrationEnabled": true
}
EOF
)"
response=$(apiRequest "POST" "/config/v1/kubernetes/credentials" "${json}")

if echo "$response" | grep -Fq "${CLUSTER_NAME}"; then
  echo "Kubernetes monitoring successfully setup."
else
  echo "Error adding Kubernetes cluster to Dynatrace: $response"
fi


# Install of nginx ingress controller
printf "\nDeployment of the Nginx Ingress controller...\n"
helm repo add nginx-stable https://helm.nginx.com/stable
helm install nginx nginx-stable/nginx-ingress --set controller.enableLatencyMetrics=true --set prometheus.create=true --set controller.config.name=nginx-config --set controller.service.annotations."service\.beta\.kubernetes\.io\/aws-load-balancer-type"="ip" --set controller.service.annotations."service\.beta\.kubernetes\.io\/aws-load-balancer-nlb-target-type"="external" --set controller.service.annotations."service\.beta\.kubernetes\.io\/aws-load-balancer-scheme"="internet-facing"
## edit the nginx config map
kubectl apply -f /home/$BASTION_USER/hotday_script/nginx/nginx-config.yaml
PODID=$(kubectl get pods --output=jsonpath={.items..metadata.name} --selector=app=ngninx-nginx-ingress)
kubectl delete pod $PODID
sleep 20
##get the id of the cluster
CLUSTERID=$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')

##deploy hipster shop
printf "\nDeployment of the Hipster-shop...\n"
kubectl create ns hipster-shop
kubectl label namespace  default monitor=dynatrace
kubectl label namespace hipster-shop   monitor=dynatrace
kubectl -n hipster-shop create rolebinding default-view --clusterrole=view --serviceaccount=hipster-shop:default
kubectl -n hipster-shop apply -f /home/$BASTION_USER/hotday_script/hipstershop/k8s-manifest.yaml

## deploy active gate
printf "\nDeployment of the Activegate...\n"
kubectl apply -f /home/$BASTION_USER/hotday_script/fluentd/service_account.yaml
kubectl create secret docker-registry tenant-docker-registry --docker-server=${ENVIRONMENT_URL} --docker-username=${ENVIRONMENT_ID} --docker-password=${PAAS_TOKEN} -n nondynatrace
kubectl create secret generic tokens --from-literal="log-ingest=${API_TOKEN}" -n nondynatrace
#### 6. Deploy active gate
sed -i "s,ENVIRONMENT_ID_TO_REPLACE,$ENVIRONMENT_ID," /home/$BASTION_USER/hotday_script/fluentd/fluentd-manifest.yaml
sed -i "s,CLUSTER_ID_TO_REPLACE,$CLUSTERID," /home/$BASTION_USER/hotday_script/fluentd/fluentd-manifest.yaml
sed -i "s,ENVIRONMENT_URL_TO_REPLACE,$ENVIRONMENT_URL," /home/$BASTION_USER/hotday_script/fluentd/activegate.yaml
### edit the various fluentd pipeline
sed -i "s,ENVIRONMENT_ID_TO_REPLACE,$ENVIRONMENT_ID," /home/$BASTION_USER/hotday_script/fluentd/fluentd-configmap-prom-stdout.yaml
sed -i "s,CLUSTER_ID_TO_REPLACE,$CLUSTERID," /home/$BASTION_USER/hotday_script/fluentd/fluentd-configmap-prom-stdout.yaml
sed -i "s,ENVIRONMENT_ID_TO_REPLACE,$ENVIRONMENT_ID," /home/$BASTION_USER/hotday_script/fluentd/fluentd-configmap-dynatrace.yaml
sed -i "s,CLUSTER_ID_TO_REPLACE,$CLUSTERID," /home/$BASTION_USER/hotday_script/fluentd/fluentd-configmap-dynatrace.yaml


printf "\nDeployment of the Fluentd...\n"
kubectl apply -f /home/$BASTION_USER/hotday_script/fluentd/activegate.yaml
kubectl apply -f /home/$BASTION_USER/hotday_script/fluentd/fluentd-manifest.yaml


## deploy prometheus operator
printf "\nDeployment of the Prometheus Operator...\n"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/prometheus

## make the load test script executable
chmod +x /home/$BASTION_USER/hotday_script/load/generateTraffic.sh
## Change owner of the folder
chown -R $BASTION_USER /home/$BASTION_USER/hotday_script