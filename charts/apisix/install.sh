registry=""
namespace=""

docker tag apache/apisix:3.2.0-debian $registry/apache/apisix:3.2.0-debian
docker tag apache/apisix-ingress-controller:1.6.0 $registry/apache/apisix-ingress-controller:1.6.0
docker tag apache/apisix-dashboard:3.0.0-alpine $registry/apache/apisix-dashboard:3.0.0-alpine
docker tag bitnami/etcd:3.5.7-debian-11-r14 $registry/bitnami/etcd:3.5.7-debian-11-r14
docker tag bitnami/bitnami-shell:11-debian-11-r90 $registry/bitnami/bitnami-shell:11-debian-11-r90
docker tag busybox:1.28 $registry/busybox:1.28

docker push $registry/apache/apisix:3.2.0-debian
docker push $registry/apache/apisix-ingress-controller:1.6.0
docker push $registry/apache/apisix-dashboard:3.0.0-alpine
docker push $registry/bitnami/etcd:3.5.7-debian-11-r14
docker push $registry/bitnami/bitnami-shell:11-debian-11-r90
docker push $registry/busybox:1.28


helm install apisix --set initContainer.image=$registry/busybox --set apisix.image.repository=$registry/apache/apisix --set etcd.image.registry=$registry --set etcd.volumePermissions.image.registry=$registry --set gateway.http.nodePort=31349 --set dashboard.image.repository=$registry/apache/apisix-dashboard --set ingress-controller.image.repository=$registry/apache/apisix-ingress-controller --set ingress-controller.config.apisix.serviceNamespace=$namespace --set ingress-controller.initContainer.image=$registry/busybox apisix-1.3.0.tgz -n $namespace --create-namespace

