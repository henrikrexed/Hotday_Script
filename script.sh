
#Deployment of Helm
curl https://baltocdn.com/helm/signing.asc | sudo apt-key add -
sudo apt-get install apt-transport-https --yes
echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm

# Clone of the repository
git clone https://github.com/henrikrexed/Hotday_Script
cd Hotday_Script/

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
kubectl -n hipster-shop create rolebinding default-view --clusterrole=view --serviceaccount=hipster-shop:default
sed -i "s,IP_TO_REPLACE,$IP," hipstershop/k8s-manifest.yaml
kubectl -n hipster-shop apply -f hipstershop/k8s-manifest.yaml

## deploy active gate
kubectl create ns nondynatrace
export ENVIRONMENT_URL=<with your environment URL (without 'http'). Example: environment.live.dynatrace.com>
export PAAS_TOKEN=<YOUR PAAS TOKEN>
export API_TOKEN=<YOUR API TOKEN>
export ENVIRONMENT_ID=<YOUR environementid in your environment url>
kubectl create secret docker-registry tenant-docker-registry --docker-server=${ENVIRONMENT_URL} --docker-username=${ENVIRONMENT_ID} --docker-password=${PAAS_TOKEN} -n dynatrace
kubectl create secret generic tokens --from-literal="log-ingest=${API_TOKEN}" -n dynatrace
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
## deploy Prometheus ServiceMonitor
kubectl apply -f prometheus/serice_nodexporter.yaml
kubectl apply -f prometheus/service.yaml