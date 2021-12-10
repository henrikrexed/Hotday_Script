#!/bin/sh
###########################################################################################################
####  Required Environment variable :
#### ENVIRONMENT_URL=<with your environment URL (without 'http'). Example: {your-environment-id}.live.dynatrace.com> or {your-domain}/e/{your-environment-id}
#### ENVIRONMENT_ID= Example: {your-environment-id}.live.dynatrace.com> , https://{your-domain}/e/{your-environment-id}/
#### API_TOKEN : api token with the following right : metric ingest, trace ingest, and log ingest and Access problem and event feed, metrics and topology
#### PAAS_TOKEN paas token
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
    shift
    ;;
  *)
    echo "Warning: skipping unsupported option: $1"
    shift
    ;;
  esac
done

if [ -z "ENVIRONMENT_URL" ]; then
  echo "Error: environment-url not set!"
  exit 1
fi

if [ -z "ENVIRONMENT_ID" ]; then
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
CLUSTER_NAME="hotday"
K8S_ENDPOINT="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
if [ -z "$K8S_ENDPOINT" ]; then
  echo "Error: failed to get kubernetes endpoint!"
  exit 1
fi

#Deployment of Helm
printf "\nDeployment of Helm...\n"
curl https://baltocdn.com/helm/signing.asc | sudo apt-key add -
sudo apt-get install apt-transport-https --yes
echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm


###Deploy dynatrace operator
printf "\nDeployment of the Dynatrace Operator...\n"
kubectl label namespace default monitor=dynatrace
kubectl create namespace dynatrace
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/latest/download/kubernetes.yaml
kubectl -n dynatrace create secret generic dynakube --from-literal="apiToken=$API_TOKEN" --from-literal="paasToken=$PAAS_TOKEN"
sed -i "s,ENVIRONMENT_URL,$ENVIRONMENT_URL," dynatrace/dynakube.yaml
kubectl -n dynatrace wait pod --for=condition=ready -l internal.dynatrace.com/app=webhook --timeout=300s
kubectl apply -n dynatrace -f dynatrace/dynakube.yaml
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
    }
  ],
  "workloadIntegrationEnabled": true,
  "eventsIntegrationEnabled": false,
  "activeGateGroup": "${CLUSTER_NAME}",
  "authToken": "${K8S_BEARER}",
  "active": true,
  "certificateCheckEnabled": "false"
}
EOF)"
response=$(apiRequest "POST" "/config/v1/kubernetes/credentials" "${json}")

if echo "$response" | grep -Fq "${CLUSTER_NAME}"; then
  echo "Kubernetes monitoring successfully setup."
else
  echo "Error adding Kubernetes cluster to Dynatrace: $response"
fi


# Install of nginx ingress controller
printf "\nDeployment of the Nginx Ingress controller...\n"
helm repo add nginx-stable https://helm.nginx.com/stable
helm install ngninx nginx-stable/nginx-ingress --set controller.enableLatencyMetrics=true --set prometheus.create=true --set controller.config.name=nginx-config
## edit the nginx config map
kubectl apply -f nginx\nginx-config.yaml
PODID=$(kubectl get pods --output=jsonpath={.items..metadata.name} --selector=app=ngninx-nginx-ingress)
kubectl delete pod $PODID

##### 3. get the ip adress of the ingress gateway
IP=$(kubectl get svc ngninx-nginx-ingress -ojson | jq -j '.status.loadBalancer.ingress[].ip')
##get the id of the cluster
CLUSTERID=$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')

##deploy hipster shop
printf "\nDeployment of the Hipster-shop...\n"
cd hipstershop
kubectl create ns hipster-shop
kubectl label hipster-shop default monitor=dynatrace
kubectl -n hipster-shop create rolebinding default-view --clusterrole=view --serviceaccount=hipster-shop:default
sed -i "s,IP_TO_REPLACE,$IP," hipstershop/k8s-manifest.yaml
kubectl -n hipster-shop apply -f hipstershop/k8s-manifest.yaml

## deploy active gate
printf "\nDeployment of the Activegate...\n"
kubectl create ns nondynatrace
kubectl create secret docker-registry tenant-docker-registry --docker-server=${ENVIRONMENT_URL} --docker-username=${ENVIRONMENT_ID} --docker-password=${PAAS_TOKEN} -n nondynatrace
kubectl create secret generic tokens --from-literal="log-ingest=${API_TOKEN}" -n nondynatrace
#### 6. Deploy active gate
sed -i "s,ENVIRONMENT_ID_TO_REPLACE,$ENVIRONMENT_ID," fluentd/fluentd-manifest.yaml
sed -i "s,CLUSTER_ID_TO_REPLACE,$CLUSTERID," fluentd/fluentd-manifest.yaml
sed -i "s,ENVIRONMENT_URL_TO_REPLACE,$ENVIRONMENT_URL," fluentd/activegate.yaml
sed -i "s,IP_TO_REPLACE,$IP," fluentd/activegate.yaml
```
printf "\nDeployment of the Fluentd...\n"
kubectl apply -f fluentd/activegate.yaml
kubectl apply -f fluentd/fluentd-manifest.yaml
```

## deploy prometheus operator
printf "\nDeployment of the Prometheus Operator...\n"
helm install prometheus stable/prometheus-operator

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