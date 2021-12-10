###########################################################################################################
####  Required Environment variable :
#### ENVIRONMENT_URL=<with your environment URL (without 'http'). Example: {your-environment-id}.live.dynatrace.com> or {your-domain}/e/{your-environment-id}
#### ENVIRONMENT_ID= Example: {your-environment-id}.live.dynatrace.com> , https://{your-domain}/e/{your-environment-id}/
#### API_TOKEN : api token with the following right : metric ingest, trace ingest, and log ingest and Access problem and event feed, metrics and topology
#### PAAS_TOKEN paas token
#########################################################################################################

#Deployment of Helm
curl https://baltocdn.com/helm/signing.asc | sudo apt-key add -
sudo apt-get install apt-transport-https --yes
echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm

# Clone of the repository
git clone https://github.com/henrikrexed/Hotday_Script
cd Hotday_Script/

###Deploy dynatrace operator
kubectl label namespace default monitor=dynatrace
kubectl create namespace dynatrace
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/latest/download/kubernetes.yaml
kubectl -n dynatrace create secret generic dynakube --from-literal="apiToken=$API_TOKEN" --from-literal="paasToken=$PAAS_TOKEN"
sed -i "s,ENVIRONMENT_URL,$ENVIRONMENT_URL," dynatrace/dynakube.yaml
kubectl apply -n dynatrace -f dynatrace/dynakube.yaml

# INstall of nginx ingress controller
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
cd hipstershop
kubectl create ns hipster-shop
kubectl label hipster-shop default monitor=dynatrace
kubectl -n hipster-shop create rolebinding default-view --clusterrole=view --serviceaccount=hipster-shop:default
sed -i "s,IP_TO_REPLACE,$IP," hipstershop/k8s-manifest.yaml
kubectl -n hipster-shop apply -f hipstershop/k8s-manifest.yaml

## deploy active gate
kubectl create ns nondynatrace

kubectl create secret docker-registry tenant-docker-registry --docker-server=${ENVIRONMENT_URL} --docker-username=${ENVIRONMENT_ID} --docker-password=${PAAS_TOKEN} -n nondynatrace
kubectl create secret generic tokens --from-literal="log-ingest=${API_TOKEN}" -n nondynatrace
#### 6. Deploy active gate
sed -i "s,ENVIRONMENT_ID_TO_REPLACE,$ENVIRONMENT_ID," fluentd/fluentd-manifest.yaml
sed -i "s,CLUSTER_ID_TO_REPLACE,$CLUSTERID," fluentd/fluentd-manifest.yaml
sed -i "s,ENVIRONMENT_URL_TO_REPLACE,$ENVIRONMENT_URL," fluentd/activegate.yaml

```
kubectl apply -f fluentd/activegate.yaml
kubectl apply -f fluentd/fluentd-manifest.yaml
```

## deploy prometheus operator
helm install prometheus stable/prometheus-operator

